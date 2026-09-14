import Foundation
import Observation

/// Owns local inference: Edge0, BaseRT, or in-process MLX.
@Observable
@MainActor
final class Runtime {

    enum Engine: String, CaseIterable, Identifiable {
        case edge0
        case basert
        case mlx
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edge0: return "Edge0"
            case .basert: return "BaseRT"
            case .mlx: return "MLX"
            }
        }
        var help: String {
            switch self {
            case .edge0: return "edge0 CLI. Streaming MoE with SSD expert offload."
            case .basert: return "The basert CLI. Converts Hugging Face weights to .base."
            case .mlx: return "Apple Silicon, in-process. Always available in this app."
            }
        }
    }

    enum Status: Equatable {
        case locating
        case missingBinary
        case noModels
        case launching(String)
        case ready(String)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    var engine: Engine {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine.rawValue, forKey: "inferenceEngine")
        }
    }
    var status: Status = .locating
    var installed: [ModelInfo] = []
    var catalog: [ModelInfo] = []
    var selectedModel: String? {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    var pullingID: String?
    var pullLog: String = ""
    var serverLog: String = ""
    /// What `basert-serve` is doing right now, for the loading bar.
    var loadPhase: String = ""
    /// Download/convert progress, driven by bytes landing in the hub cache.
    var pullPhase: String = ""
    var pullReceived: Int64 = 0
    var pullExpected: Int64?
    /// Overall 0…1 for the bar. Kept separate from byte counts because Hub
    /// `completedUnitCount` is per-file while `fractionCompleted` is overall.
    var pullFraction: Double = 0
    /// What the Models sheet actually draws — always `fraction × expected`
    /// once we know a real total, so the label cannot stick on the first shard.
    var pullShownReceived: Int64 = 0
    var pullShownExpected: Int64?
    /// Ready-to-draw "12 MB of 4.2 GB". Built here so the sheet cannot mix
    /// shard bytes with the overall percent.
    var pullSizeLabel: String = ""
    /// Hub pulls (Edge0/MLX): the percent string is overall `Progress` fraction,
    /// so the byte label must be `fraction × total`. Disk bytes are the first
    /// finished shard and must not be mixed in. BaseRT uses disk bytes.
    private var pullTracksHubFraction = false
    /// BaseRT's convert step: bytes the `.base` output has grown since the
    /// phase started, and what it is expected to end at when the remote
    /// catalog listed a size for this variant.
    private var convertStarted = false
    private var convertBaseline: Int64 = 0
    private var convertWritten: Int64 = 0
    private var convertExpected: Int64?

    private(set) var port: UInt16 = 8453
    /// The id `basert serve` actually registered — the API rejects anything else.
    private(set) var serverModelID: String?
    private var apiKey = UUID().uuidString
    private var binURL: URL?
    private var serveURL: URL?
    private var server: Process?
    private var edge0Launch: Edge0Launch?
    /// Bumped every `start` so a superseded launch loop exits.
    private var startToken = UUID()
    let mlx = MLXEngine()
    /// Engines whose runtime is present on this Mac. MLX is always in this list.
    private(set) var availableEngines: [Engine] = [.mlx]
    private(set) var lastTokensPerSecond: Double?
    private(set) var lastMemoryBytes: Int?
    private var pullWork: Task<Void, Never>?

    var apiURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var apiToken: String { apiKey }
    var usesHTTP: Bool { engine == .basert || engine == .edge0 }

    init() {
        // Probe PATH / Python off the main actor in `bootstrap`. Until then
        // MLX is always a valid engine so the window can open.
        self.engine = .mlx
        selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
    }

    var memoryLabel: String? {
        guard let bytes = lastMemoryBytes, bytes > 0 else { return nil }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .memory
        return fmt.string(fromByteCount: Int64(bytes))
    }

    /// Edge0, then BaseRT, then MLX — first one that is actually installed.
    static func preferred(in available: [Engine]) -> Engine {
        for candidate in [Engine.edge0, .basert, .mlx] where available.contains(candidate) {
            return candidate
        }
        return .mlx
    }

    nonisolated static func detectAvailable() -> [Engine] {
        var found: [Engine] = []
        if Edge0Engine.locate() != nil { found.append(.edge0) }
        if locateBinary() != nil { found.append(.basert) }
        found.append(.mlx)
        return found
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        ProcessTree.reapOrphans()
        await rescanEngines()
        switch engine {
        case .edge0:
            await bootstrapEdge0()
        case .mlx:
            await bootstrapMLX()
        case .basert:
            await bootstrapBaseRT()
        }
    }

    func switchEngine(to next: Engine) async {
        guard next != engine else { return }
        cancelPull()
        await stopAll()
        engine = next
        installed = []
        catalog = []
        status = .locating
        await bootstrap()
    }

    /// Re-read PATH and `python3 -m edge0` without restarting the app.
    func rescanEngines() async {
        let found = await Task.detached { Self.detectAvailable() }.value
        availableEngines = found
        if let stored = UserDefaults.standard.string(forKey: "inferenceEngine"),
           let wanted = Engine(rawValue: stored),
           found.contains(wanted) {
            if engine != wanted { engine = wanted }
        } else {
            let pick = Self.preferred(in: found)
            if engine != pick { engine = pick }
        }
    }

    private func bootstrapEdge0() async {
        guard let launch = Edge0Engine.locate() else {
            engine = Self.preferred(in: availableEngines.filter { $0 != .edge0 })
            await bootstrap()
            return
        }
        edge0Launch = launch
        await refreshInstalled()
        let target = selectedModel.flatMap { id in installed.first { $0.id == id }?.id }
            ?? installed.first?.id
        if let target {
            await start(model: target)
        } else {
            status = .noModels
        }
    }

    private func bootstrapMLX() async {
        await refreshInstalled()
        let target = selectedModel.flatMap { id in installed.first { $0.id == id }?.id }
            ?? installed.first?.id
        if let target {
            await start(model: target)
        } else {
            status = .noModels
        }
    }

    private func bootstrapBaseRT() async {
        guard let bin = Self.locateBinary() else {
            engine = Self.preferred(in: availableEngines.filter { $0 != .basert })
            await bootstrap()
            return
        }
        binURL = bin
        let sibling = bin.deletingLastPathComponent().appendingPathComponent("basert-serve")
        serveURL = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
        await refreshInstalled()
        let target = selectedModel.flatMap { id in installed.first { $0.id == id }?.id } ?? installed.first?.id
        if let target {
            await start(model: target)
        } else {
            status = .noModels
        }
    }

    func select(model id: String) async {
        guard id != selectedModel || !status.isReady else { return }
        await start(model: id)
    }

    func start(model id: String) async {
        cancelPull()
        mlx.resetSession()
        let token = UUID()
        startToken = token
        switch engine {
        case .edge0:
            await startEdge0(id: id, token: token)
        case .mlx:
            await startMLX(id: id, token: token)
        case .basert:
            await startBaseRT(id: id, token: token)
        }
    }

    private func startEdge0(id: String, token: UUID) async {
        await stopAll()
        guard startToken == token else { return }
        guard let launch = edge0Launch ?? Edge0Engine.locate() else {
            status = .missingBinary
            return
        }
        edge0Launch = launch
        if installed.isEmpty { await refreshInstalled() }
        guard let tier = Edge0Engine.tier(matching: id)
                ?? installed.first(where: { $0.id == id }).flatMap({ Edge0Engine.tier(matching: $0.modelID) }),
              let checkpoint = Edge0Engine.checkpoint(for: tier)
        else {
            status = .failed("No Edge0 checkpoint for \(id). Download one from Models.")
            return
        }
        selectedModel = tier.id
        serverModelID = nil
        serverLog = ""
        status = .launching(tier.id)
        loadPhase = "Starting Edge0"
        port = Self.freePort(startingAt: 8000)
        apiKey = ""

        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"], uniquingKeysWith: { _, new in new }
        )
        switch launch {
        case .binary(let bin):
            process.executableURL = bin
            process.arguments = Edge0Engine.serveArguments(checkpoint: checkpoint, port: port)
        case .pythonModule(let python):
            process.executableURL = python
            process.arguments = ["-m", "edge0"] + Edge0Engine.serveArguments(checkpoint: checkpoint, port: port)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in
                self.serverLog = String((self.serverLog + text).suffix(8000))
                self.noteLoadPhase(text)
            }
        }

        do {
            try process.run()
        } catch {
            status = .failed("Could not launch edge0: \(error.localizedDescription)")
            return
        }
        ProcessTree.detach(process)
        server = process

        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard startToken == token else {
                ProcessTree.stop(process)
                if server === process { server = nil }
                return
            }
            if !process.isRunning {
                status = .failed("edge0 serve exited. Check the log below.")
                return
            }
            if await ping() {
                status = .ready(tier.id)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard startToken == token else { return }
        status = .failed("Timed out waiting for edge0 serve.")
    }

    private func startMLX(id: String, token: UUID) async {
        await stopAll()
        guard startToken == token else { return }
        selectedModel = id
        serverModelID = id
        status = .launching(id)
        loadPhase = "Loading model into memory"
        do {
            try await mlx.load(id: id) { [weak self] update in
                guard let self, self.startToken == token else { return }
                self.loadPhase = update.label
                self.lastMemoryBytes = self.mlx.memoryBytes
                if update.label == "Ready" {
                    self.status = .ready(id)
                }
            }
            guard startToken == token else { return }
            lastMemoryBytes = mlx.memoryBytes
            status = .ready(id)
        } catch {
            guard startToken == token else { return }
            status = .failed(error.localizedDescription)
        }
    }

    private func startBaseRT(id: String, token: UUID) async {
        await stopAll()
        guard startToken == token else { return }
        guard let bin = binURL else { return }
        if installed.isEmpty { await refreshInstalled() }
        selectedModel = id
        serverModelID = nil
        serverLog = ""
        status = .launching(id)
        loadPhase = "Starting engine"
        port = Self.freePort(startingAt: 8453)
        apiKey = UUID().uuidString

        // `basert serve` resolves the model then hands off to `basert-serve` and exits,
        // which would orphan the server. Launch the real binary ourselves when we can.
        let modelPath = installed.first { $0.id == id }?.path
        let process = Process()
        var options = [
            "--host", "127.0.0.1",
            "--port", String(port),
            "--max-context", "8192",
            "--max-tokens", "4096",
            "--api-key", apiKey,
        ]
        if let serveURL, let modelPath {
            process.executableURL = serveURL
            options.insert(modelPath, at: 0)
        } else {
            process.executableURL = bin
            options.insert(contentsOf: ["serve", id], at: 0)
        }
        process.arguments = options
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in
                self.serverLog = String((self.serverLog + text).suffix(8000))
                self.noteLoadPhase(text)
            }
        }

        do {
            try process.run()
        } catch {
            status = .failed("Could not launch basert: \(error.localizedDescription)")
            return
        }
        ProcessTree.detach(process)
        server = process

        // The first launch of a model can convert/load for a while.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            guard startToken == token else {
                ProcessTree.stop(process)
                if server === process { server = nil }
                return
            }
            if !process.isRunning {
                status = .failed("basert serve exited. Check the log below.")
                return
            }
            if await ping() {
                status = .ready(id)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard startToken == token else { return }
        status = .failed("Timed out waiting for basert serve.")
    }

    /// One place the composer and the local server both talk to.
    func complete(
        history: [Message],
        chatID: UUID? = nil,
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        topK: Int,
        maxTokens: Int,
        frequencyPenalty: Double,
        onDelta: @escaping @MainActor (String) async -> Void,
        onReasoning: @escaping @MainActor (String) async -> Void = { _ in }
    ) async throws -> CompletionInfo {
        guard status.isReady else {
            throw ChatClient.APIError(message: "No model is running.")
        }
        let trimmed = HistoryTrim.apply(history, maxTokens: maxTokens)
        let splitter = ThinkSplitter()
        var tokensPerSecond: Double?

        func ingest(_ chunk: String) async {
            let parts = splitter.push(chunk)
            if !parts.reasoning.isEmpty { await onReasoning(parts.reasoning) }
            if !parts.answer.isEmpty { await onDelta(parts.answer) }
        }

        switch engine {
        case .mlx:
            try await mlx.stream(
                history: trimmed.messages,
                chatID: chatID,
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                topK: topK,
                maxTokens: maxTokens,
                frequencyPenalty: frequencyPenalty
            ) { event in
                switch event {
                case .chunk(let text) where !text.isEmpty:
                    await ingest(text)
                case .info(let info):
                    tokensPerSecond = info.tokensPerSecond
                default:
                    break
                }
            }
        case .basert, .edge0:
            let model = serverModelID ?? selectedModel ?? ""
            let client = ChatClient(
                baseURL: apiURL,
                model: model,
                apiKey: apiToken,
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                topK: topK,
                maxTokens: maxTokens,
                frequencyPenalty: frequencyPenalty
            )
            try await client.send(trimmed.messages, onDelta: ingest)
        }

        let rest = splitter.finish()
        if !rest.reasoning.isEmpty { await onReasoning(rest.reasoning) }
        if !rest.answer.isEmpty { await onDelta(rest.answer) }

        lastTokensPerSecond = tokensPerSecond
        lastMemoryBytes = engine == .mlx ? mlx.memoryBytes : nil
        return CompletionInfo(
            tokensPerSecond: tokensPerSecond,
            trimmed: trimmed.trimmed,
            memoryBytes: lastMemoryBytes
        )
    }

    private func noteLoadPhase(_ text: String) {
        if text.contains("Listening on") || text.contains("serving ") {
            loadPhase = "Ready"
            if case .launching(let id) = status { status = .ready(id) }
        } else if text.contains("Model loaded") { loadPhase = "Starting server" }
        else if text.contains("Loading model") { loadPhase = "Loading model into memory" }
        else if text.contains("Starting BaseRT") && loadPhase.isEmpty { loadPhase = "Starting engine" }
        else if text.contains("[edge0]") && loadPhase.isEmpty { loadPhase = "Loading Edge0" }
    }

    func stopServer() {
        if let server {
            (server.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            let process = server
            self.server = nil
            ProcessTree.stop(process)
        }
        ProcessTree.reapOrphans()
    }

    func stopAll() async {
        stopServer()
        mlx.unload()
        serverModelID = nil
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// Returns true once the server answers — and records the model id it registered.
    private func ping() async -> Bool {
        var request = URLRequest(url: apiURL.appending(path: "v1/models"))
        request.timeoutInterval = 2
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        serverModelID = (try? JSONDecoder().decode(ModelList.self, from: data))?.data.first?.id
        return serverModelID != nil
    }

    // MARK: - Model management

    func refreshInstalled() async {
        if pullingID == nil {
            // Only forgets half-finished repos; their Hub folders stay on disk
            // so the next pull resumes from the shards that already landed.
            mlx.sweepIncomplete()
        }
        switch engine {
        case .edge0:
            installed = Edge0Engine.installed()
        case .mlx:
            installed = mlx.models(installed: true)
        case .basert:
            guard let bin = binURL else { return }
            let out = try? await Self.run(bin, ["list", "--json"])
            installed = Self.decode(out?.stdout) ?? []
        }
    }

    func refreshCatalog() async {
        switch engine {
        case .edge0:
            catalog = Edge0Engine.catalog()
        case .mlx:
            catalog = mlx.models(installed: false)
        case .basert:
            guard let bin = binURL else { return }
            let out = try? await Self.run(bin, ["list", "--remote", "--json"])
            let all: [ModelInfo] = Self.decode(out?.stdout) ?? []
            // `basert pull` picks the variant via its own profile, so collapse the
            // per-variant rows into one entry per model id.
            var seen = Set<String>()
            catalog = all.filter { !$0.installed && seen.insert($0.modelID).inserted }
        }
    }

    /// Catalog id or any Hugging Face `org/model` repo.
    func pull(id rawID: String, target: String?) async {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pullingID == nil else { return }
        pullWork = Task { @MainActor in
            switch engine {
            case .edge0:
                await pullEdge0(trimmed)
            case .mlx:
                await pullMLX(trimmed)
            case .basert:
                await pullBaseRT(trimmed, target: target)
            }
        }
        await pullWork?.value
    }

    func cancelPull() {
        pullWork?.cancel()
        pullWork = nil
        if pullingID != nil {
            pullLog += "\nCancelled.\n"
            pullPhase = "Cancelled"
            pullingID = nil
        }
    }

    private func pullEdge0(_ raw: String) async {
        guard let tier = Edge0Engine.tier(matching: raw) else {
            pullLog = "Unknown Edge0 model. Use edge0-8b or edge0-35b.\n"
            pullPhase = "Failed"
            return
        }
        pullingID = tier.id
        pullLog = "Pulling \(tier.hub)…\n"
        pullPhase = "Downloading"
        pullReceived = 0
        pullExpected = nil
        pullFraction = 0
        pullShownReceived = 0
        pullShownExpected = nil
        pullSizeLabel = ""
        pullTracksHubFraction = true
        if let expected = await MLXEngine.expectedDownloadBytes(
            for: tier.hub, extraSuffixes: [".txt", ".model"]
        ) {
            pullExpected = expected
        } else {
            pullExpected = tier.sizeBytes
        }
        if let catalog = Edge0Engine.tier(matching: raw)?.sizeBytes,
           (pullExpected ?? 0) < catalog {
            pullExpected = catalog
        }
        publishPullProgress()
        let meter = meterHubCache(for: tier.hub)
        defer { meter.cancel() }
        do {
            let downloader = HubBridge()
            try Task.checkCancellation()
            let url = try await downloader.download(
                id: tier.hub,
                revision: "main",
                matching: ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model"],
                useLatest: false
            ) { progress in
                Task { @MainActor in
                    self.applyLiveFraction(progress.fractionCompleted)
                }
            }
            try Task.checkCancellation()
            if Edge0Engine.isCheckpoint(url) {
                Edge0Engine.remember(url, for: tier)
            } else if let snap = MLXEngine.hubSnapshot(for: tier.hub) {
                Edge0Engine.remember(snap, for: tier)
            }
            pullLog += "\nDone.\n"
            pullPhase = "Installed"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
            if !status.isReady {
                await start(model: tier.id)
            }
        } catch is CancellationError {
            // Partials stay in the Hub cache — the catalog row turns into
            // "Resume" and completed shards are skipped on the next pull.
            pullLog += "\nCancelled. Partial download kept — use Resume to continue.\n"
            pullPhase = "Cancelled"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
        } catch {
            pullLog += "\nFailed: \(error.localizedDescription)\nPartial download kept — use Resume to continue.\n"
            pullPhase = "Failed"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
        }
    }

    private func pullMLX(_ id: String) async {
        pullingID = id
        pullLog = "Pulling \(id)…\n"
        pullPhase = "Downloading"
        pullReceived = 0
        pullExpected = nil
        pullFraction = 0
        pullShownReceived = 0
        pullShownExpected = nil
        pullSizeLabel = ""
        pullTracksHubFraction = true

        let api = await MLXEngine.expectedDownloadBytes(for: id)
        if let api, api >= 80_000_000 {
            pullExpected = api
        } else {
            pullExpected = MLXEngine.catalogByteSize(for: id)
        }
        publishPullProgress()
        let meter = meterHubCache(for: id)
        defer { meter.cancel() }

        do {
            try Task.checkCancellation()
            try await mlx.download(id: id) { [weak self] update in
                guard let self else { return }
                if let fraction = update.fraction {
                    self.applyLiveFraction(fraction)
                } else if update.label != "Installed" {
                    self.pullPhase = update.label
                }
            }
            pullLog += "\nDone.\n"
            pullPhase = "Installed"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
            if !status.isReady {
                await start(model: id)
            }
        } catch is CancellationError {
            pullLog += "\nCancelled. Partial download kept — use Resume to continue.\n"
            pullPhase = "Cancelled"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
        } catch {
            pullLog += "\nFailed: \(error.localizedDescription)\nPartial download kept — use Resume to continue.\n"
            pullPhase = "Failed"
            pullingID = nil
            await refreshInstalled()
            await refreshCatalog()
        }
    }

    private func pullBaseRT(_ trimmed: String, target: String?) async {
        guard let bin = binURL else { return }

        pullingID = trimmed
        pullLog = "Pulling \(trimmed)…\n"
        pullPhase = "Preparing"
        pullReceived = 0
        pullExpected = nil
        pullFraction = 0
        pullShownReceived = 0
        pullShownExpected = nil
        pullSizeLabel = ""
        pullTracksHubFraction = false
        convertStarted = false
        convertBaseline = 0
        convertWritten = 0
        convertExpected = nil
        var args = ["pull", trimmed]
        if let target, !target.isEmpty { args += ["--target", target] }

        // What the converted variant should weigh, from the remote catalog —
        // the denominator of the conversion percent. Runs beside the pull so
        // a slow registry does not delay the download bar.
        let lookup = Task { [weak self] in
            guard let out = try? await Self.run(bin, ["list", "--remote", "--json"]) else { return }
            let all: [ModelInfo] = Self.decode(out.stdout) ?? []
            let match = all.first { $0.modelID == trimmed && $0.variant == target }
                ?? all.first { $0.modelID == trimmed }
            guard let size = match?.sizeBytes, size > 10_000_000 else { return }
            await MainActor.run {
                guard let self, self.pullingID == trimmed else { return }
                self.convertExpected = size
            }
        }

        // The CLI hides its progress bar when stdout is a pipe, so measure the
        // bytes arriving in the hub cache instead. The downloader preallocates
        // each blob sparsely, so the file's *logical* size is the exact target
        // and its *allocated* blocks are what has actually landed — using
        // logical size for both would read 100% two seconds in.
        let alreadyInstalled = installed.contains { $0.modelID == trimmed }
        let baseline = Self.cacheStats(for: trimmed)
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let now = Self.cacheStats(for: trimmed)
                let received = max(0, now.allocated - baseline.allocated)
                let expected = now.logical - baseline.logical
                let converted = Self.cacheStats(for: trimmed, includeSource: false).allocated
                await MainActor.run {
                    guard let self else { return }
                    if self.convertStarted {
                        self.convertWritten = max(0, converted - self.convertBaseline)
                    }
                    self.notePullBytes(received: received, expected: expected > 0 ? expected : nil)
                }
            }
        }

        let code = await Self.stream(bin, args) { line in
            Task { @MainActor in
                self.pullLog = String((self.pullLog + line).suffix(8000))
                self.notePullPhase(line)
            }
        }
        meter.cancel()
        lookup.cancel()

        if code != 0, !alreadyInstalled {
            discardIncompleteBaseRT(trimmed)
        }
        pullLog += code == 0 ? "\nDone.\n" : "\nFailed (exit \(code)).\n"
        pullPhase = code == 0 ? "Installed" : "Failed"
        pullingID = nil
        await refreshInstalled()
        await refreshCatalog()

        if code == 0, !status.isReady, let first = installed.first(where: { $0.modelID == trimmed }) ?? installed.first {
            await start(model: first.id)
        }
    }

    private func discardHubPull(_ id: String) {
        mlx.forget(id)
        MLXEngine.purgeCache(for: id)
        if let tier = Edge0Engine.tier(matching: id) ?? Edge0Engine.tiers.first(where: { $0.hub == id }) {
            Edge0Engine.forget(tier)
        }
    }

    /// Throws away a partial Hub download (Models sheet ✕) so the next pull
    /// starts from zero.
    func discardPartial(_ modelID: String) async {
        let id = Edge0Engine.tier(matching: modelID)?.hub ?? modelID
        discardHubPull(id)
        await refreshInstalled()
        await refreshCatalog()
    }

    private func discardIncompleteBaseRT(_ modelID: String) {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/baseRT/models")
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        let src = cache.appendingPathComponent(".src/hf/models--\(slug)")
        let dest = cache.appendingPathComponent(modelID)
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dest.path)) ?? []
        let hasBase = names.contains { $0.hasSuffix(".base") }
        if !hasBase {
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: dest)
        }
    }

    private func notePullPhase(_ line: String) {
        let lower = line.lowercased()
        if lower.contains("installed") { pullPhase = "Installed" }
        else if lower.contains("convert") || lower.contains("quantiz") {
            if !convertStarted {
                convertStarted = true
                convertBaseline = Self.cacheStats(for: pullingID ?? "", includeSource: false).allocated
                convertWritten = 0
            }
            pullPhase = "Converting to .base"
        }
        else if lower.contains("sha256") { pullPhase = "Verifying checksum" }
        else if lower.contains("catalog:") || lower.contains("resolving") { pullPhase = "Downloading" }
    }

    /// Live Hub bytes from parent `Progress.fractionCompleted` × known total.
    /// `completedUnitCount` is the current file and must not be used as size.
    private func applyLiveFraction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let clamped = min(max(fraction, 0), 1)
        if clamped > pullFraction { pullFraction = clamped }
        publishPullProgress()
    }

    /// `received` is a floor: never shrink an in-flight estimate.
    private func notePullBytes(received: Int64, expected: Int64?) {
        if let expected, expected > 0 {
            pullExpected = expected
        }
        if received > pullReceived {
            pullReceived = received
        }
        if !pullTracksHubFraction, let total = pullExpected, total > 0 {
            pullFraction = min(1, Double(pullReceived) / Double(total))
        }
        publishPullProgress()
    }

    private func publishPullProgress() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // Anything under 80 MB is a tokenizer JSON, not a model.
        let total = pullExpected.flatMap { $0 >= 80_000_000 ? $0 : nil }
        pullShownExpected = total
        if pullTracksHubFraction, let total {
            let bytes = Int64((min(1, max(0, pullFraction)) * Double(total)).rounded())
            pullShownReceived = min(total, max(0, bytes))
            pullSizeLabel = "\(formatter.string(fromByteCount: pullShownReceived)) of \(formatter.string(fromByteCount: total))"
        } else if let total {
            pullShownReceived = min(total, max(0, pullReceived))
            pullSizeLabel = "\(formatter.string(fromByteCount: pullShownReceived)) of \(formatter.string(fromByteCount: total))"
        } else {
            pullShownReceived = pullReceived
            pullSizeLabel = pullReceived > 0 ? formatter.string(fromByteCount: pullReceived) : ""
        }
        let converting = pullPhase.localizedCaseInsensitiveContains("convert")
            || pullPhase.localizedCaseInsensitiveContains("verif")
        if converting {
            // The download percent no longer applies; report the `.base` output
            // growing instead — as a percent when the catalog named a size.
            guard convertStarted, convertWritten > 0,
                  pullPhase.localizedCaseInsensitiveContains("convert")
            else { return }
            if let expected = convertExpected, expected > 0 {
                let pct = min(99, max(1, Int((Double(convertWritten) / Double(expected) * 100).rounded())))
                pullPhase = "Converting to .base — \(pct) %"
            } else {
                pullPhase = "Converting to .base — \(formatter.string(fromByteCount: convertWritten)) written"
            }
            return
        }
        let pct = min(100, Int((pullFraction * 100).rounded()))
        pullPhase = "\(pct) %"
    }

    /// Poll the Hugging Face blob cache while a Hub snapshot download runs.
    /// Files only appear in `blobs/` after each shard finishes; live bytes
    /// come from `applyLiveFraction` on the parent Progress.
    private func meterHubCache(for id: String) -> Task<Void, Never> {
        let baseline = MLXEngine.hubCacheStats(for: id)
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let now = MLXEngine.hubCacheStats(for: id)
                let inflight = MLXEngine.inflightDownloadBytes()
                let received = max(0, now.allocated - baseline.allocated) + inflight
                let logical = max(0, now.logical - baseline.logical)
                await MainActor.run {
                    guard let self else { return }
                    if self.pullExpected == nil, logical >= 10_000_000 {
                        self.pullExpected = logical
                    }
                    self.notePullBytes(received: received, expected: nil)
                }
            }
        }
    }

    /// Bytes on disk for a model id: the shared HF blob cache plus the installed tree.
    /// `allocated` is what has really been written; `logical` is the preallocated target size.
    /// `includeSource: false` measures only the converted output tree.
    private nonisolated static func cacheStats(
        for modelID: String, includeSource: Bool = true
    ) -> (allocated: Int64, logical: Int64) {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/baseRT/models")
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        var roots = [cache.appendingPathComponent(modelID)]
        if includeSource {
            roots.append(cache.appendingPathComponent(".src/hf/models--\(slug)"))
        }
        var allocated: Int64 = 0
        var logical: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys)
            ) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true
                else { continue }
                logical += Int64(values.fileSize ?? 0)
                allocated += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return (allocated, logical)
    }

    /// Moves a model's files to the Trash.
    func delete(_ model: ModelInfo) async {
        if engine == .edge0, let tier = Edge0Engine.tier(matching: model.modelID) {
            let wasActive = model.id == selectedModel || model.modelID == selectedModel
            if wasActive { await stopAll() }
            if let path = model.path {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
            Edge0Engine.forget(tier)
            await refreshInstalled()
            await refreshCatalog()
            if wasActive {
                if let next = installed.first {
                    await start(model: next.id)
                } else {
                    selectedModel = nil
                    status = .noModels
                }
            }
            return
        }
        if engine == .mlx {
            let wasActive = model.id == selectedModel || model.modelID == selectedModel
            if wasActive { await stopAll() }
            mlx.forget(model.modelID)
            await refreshInstalled()
            await refreshCatalog()
            if wasActive {
                if let next = installed.first {
                    await start(model: next.id)
                } else {
                    selectedModel = nil
                    status = .noModels
                }
            }
            return
        }
        guard let path = model.path else { return }
        let variantDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let wasActive = model.id == selectedModel
        if wasActive {
            stopServer()
            serverModelID = nil
        }
        try? FileManager.default.trashItem(at: variantDirectory, resultingItemURL: nil)

        // Drop the model folder too if that was its last variant.
        let modelDirectory = variantDirectory.deletingLastPathComponent()
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: modelDirectory.path),
           leftovers.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? FileManager.default.trashItem(at: modelDirectory, resultingItemURL: nil)
        }

        await refreshInstalled()
        await refreshCatalog()
        if wasActive {
            if let next = installed.first {
                await start(model: next.id)
            } else {
                selectedModel = nil
                status = .noModels
            }
        }
    }

    // MARK: - Process helpers

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func run(_ bin: URL, _ args: [String]) async throws -> (code: Int32, stdout: Data) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = bin
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { finished in
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: (finished.terminationStatus, data))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private nonisolated static func stream(
        _ bin: URL,
        _ args: [String],
        onOutput: @escaping (String) -> Void
    ) async -> Int32 {
        let process = Process()
        process.executableURL = bin
        process.arguments = args
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                    onOutput(text)
                }
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Discovery

    nonisolated static func locateBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".basert/basert"),
            URL(fileURLWithPath: "/opt/homebrew/bin/basert"),
            URL(fileURLWithPath: "/usr/local/bin/basert"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// First TCP port we can actually bind on loopback.
    static func freePort(startingAt start: UInt16) -> UInt16 {
        for candidate in start..<(start + 32) where isFree(candidate) { return candidate }
        return start
    }

    private static func isFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
