import Foundation
import Observation

/// Owns the `basert` CLI: model list, downloads, and the local OpenAI-compatible server.
@Observable
@MainActor
final class Runtime {

    enum Status: Equatable {
        case locating
        case missingBinary
        case noModels
        case launching(String)
        case ready(String)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
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

    private(set) var port: UInt16 = 8453
    /// The id `basert serve` actually registered — the API rejects anything else.
    private(set) var serverModelID: String?
    private var apiKey = UUID().uuidString
    private var binURL: URL?
    private var serveURL: URL?
    private var server: Process?

    var apiURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var apiToken: String { apiKey }

    init() {
        selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard binURL == nil else { return }
        guard let bin = Self.locateBinary() else {
            status = .missingBinary
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
        stopServer()
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
        server = process

        // The first launch of a model can convert/load for a while.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
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
        status = .failed("Timed out waiting for basert serve.")
    }

    private func noteLoadPhase(_ text: String) {
        if text.contains("Listening on") { loadPhase = "Ready" }
        else if text.contains("Model loaded") { loadPhase = "Starting server" }
        else if text.contains("Loading model") { loadPhase = "Loading model into memory" }
        else if text.contains("Starting BaseRT") && loadPhase.isEmpty { loadPhase = "Starting engine" }
    }

    func stopServer() {
        guard let server else { return }
        (server.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if server.isRunning { server.terminate() }
        self.server = nil
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// Returns true once the server answers — and records the model id it registered.
    private func ping() async -> Bool {
        var request = URLRequest(url: apiURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 2
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        serverModelID = (try? JSONDecoder().decode(ModelList.self, from: data))?.data.first?.id
        return serverModelID != nil
    }

    // MARK: - Model management

    func refreshInstalled() async {
        guard let bin = binURL else { return }
        let out = try? await Self.run(bin, ["list", "--json"])
        installed = Self.decode(out?.stdout) ?? []
    }

    func refreshCatalog() async {
        guard let bin = binURL else { return }
        let out = try? await Self.run(bin, ["list", "--remote", "--json"])
        let all: [ModelInfo] = Self.decode(out?.stdout) ?? []
        // `basert pull` picks the variant via its own profile, so collapse the
        // per-variant rows into one entry per model id.
        var seen = Set<String>()
        catalog = all.filter { !$0.installed && seen.insert($0.modelID).inserted }
    }

    /// `basert pull <id>` — catalog id or any Hugging Face `org/model` repo.
    func pull(id rawID: String, target: String?) async {
        guard let bin = binURL, pullingID == nil else { return }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pullingID = trimmed
        pullLog = "Pulling \(trimmed)…\n"
        pullPhase = "Preparing"
        pullReceived = 0
        pullExpected = nil
        var args = ["pull", trimmed]
        if let target, !target.isEmpty { args += ["--target", target] }

        // The CLI hides its progress bar when stdout is a pipe, so measure the
        // bytes arriving in the hub cache instead. The downloader preallocates
        // each blob sparsely, so the file's *logical* size is the exact target
        // and its *allocated* blocks are what has actually landed — using
        // logical size for both would read 100% two seconds in.
        let baseline = Self.cacheStats(for: trimmed)
        let meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let now = Self.cacheStats(for: trimmed)
                let received = max(0, now.allocated - baseline.allocated)
                let expected = now.logical - baseline.logical
                await MainActor.run {
                    self?.pullReceived = received
                    self?.pullExpected = expected > 0 ? expected : nil
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

        pullLog += code == 0 ? "\nDone.\n" : "\nFailed (exit \(code)).\n"
        pullPhase = code == 0 ? "Installed" : "Failed"
        pullingID = nil
        await refreshInstalled()
        await refreshCatalog()

        if code == 0, !status.isReady, let first = installed.first(where: { $0.modelID == trimmed }) ?? installed.first {
            await start(model: first.id)
        }
    }

    private func notePullPhase(_ line: String) {
        let lower = line.lowercased()
        if lower.contains("installed") { pullPhase = "Installed" }
        else if lower.contains("convert") || lower.contains("quantiz") { pullPhase = "Converting to .base" }
        else if lower.contains("sha256") { pullPhase = "Verifying checksum" }
        else if lower.contains("catalog:") || lower.contains("resolving") { pullPhase = "Downloading" }
    }

    /// Bytes on disk for a model id: the shared HF blob cache plus the installed tree.
    /// `allocated` is what has really been written; `logical` is the preallocated target size.
    private nonisolated static func cacheStats(for modelID: String) -> (allocated: Int64, logical: Int64) {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/baseRT/models")
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        let roots = [
            cache.appendingPathComponent(".src/hf/models--\(slug)"),
            cache.appendingPathComponent(modelID),
        ]
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

    /// Moves a model's files to the Trash — BaseRT has no `rm` subcommand.
    func delete(_ model: ModelInfo) async {
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
                let data = out.fileHandleForReading.readDataToEndOfFile()
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
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = bin
            process.arguments = args
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
    }

    // MARK: - Discovery

    static func locateBinary() -> URL? {
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
