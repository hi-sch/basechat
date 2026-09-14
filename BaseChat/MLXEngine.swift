import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Hugging Face adapters (no macros — Xcode would otherwise
// refuse MLXHuggingFaceMacros until the user clicked Trust)

enum HubTransport {
    /// Downloads of multi-GB shards stall out on the default 60s request timeout.
    static let client: HubClient = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15 * 60
        config.timeoutIntervalForResource = 24 * 3600
        config.waitsForConnectivity = true
        return HubClient(session: URLSession(configuration: config))
    }()
}

struct HubBridge: MLXLMCommon.Downloader {
    private let upstream: HubClient
    init(_ upstream: HubClient = HubTransport.client) { self.upstream = upstream }

    /// Network hiccups that are worth another attempt. Completed files are
    /// already in the blob cache, so a retry only re-fetches what is missing.
    private static let transientCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed,
    ]

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest _: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw ChatClient.APIError(message: "Not a Hugging Face repo id: \(id)")
        }
        var attempt = 0
        while true {
            do {
                return try await upstream.downloadSnapshot(
                    of: repoID,
                    revision: revision ?? "main",
                    matching: patterns,
                    localFilesOnly: false,
                    progressHandler: { @MainActor progress in
                        progressHandler(progress)
                    }
                )
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                if let code = (error as? URLError)?.code, code == .cancelled { throw error }
                attempt += 1
                let transient = (error as? URLError).map { Self.transientCodes.contains($0.code) } ?? false
                guard transient, attempt < 3 else { throw error }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// In-process MLX inference: Hub download, Metal load, token stream.
/// Isolated here so the rest of the app never has to name `MLXLMCommon.Chat`.
@MainActor
final class MLXEngine {

    private(set) var container: ModelContainer?
    private(set) var loadedID: String?
    /// Bumped by every `load` and `unload` so a superseded load — a model
    /// switch during a multi-GB fetch — cannot assign its container over the
    /// newer one when it finally finishes.
    private var loadToken = UUID()
    /// Multi-turn session so the KV cache survives from one send to the next.
    private var session: ChatSession?
    private var sessionChat: UUID?
    private var sessionPrompt: String = ""
    private var sessionFed = 0

    /// Hugging Face ids we have successfully pulled (or found already cached).
    private(set) var installedIDs: [String] = []

    private static let installedKey = "mlxInstalledIDs"

    init() {
        installedIDs = (UserDefaults.standard.stringArray(forKey: Self.installedKey) ?? [])
            .filter { Self.isMLXRepo($0) }
        Self.tuneMemory()
        installedIDs = Self.mergeCached(with: installedIDs)
        persistInstalled()
    }

    // MARK: Catalog

    /// Rough installed size of the 4-bit catalog weights. Used when Hub
    /// metadata only reports the first JSON (~1 MB).
    static func catalogByteSize(for id: String) -> Int64? {
        let sizes: [String: Int64] = [
            "mlx-community/Qwen3-0.6B-4bit": 520_000_000,
            "mlx-community/Qwen3-1.7B-4bit": 1_100_000_000,
            "mlx-community/Qwen3-4B-4bit": 2_400_000_000,
            "mlx-community/Qwen3-8B-4bit": 4_700_000_000,
            "mlx-community/Llama-3.2-1B-Instruct-4bit": 700_000_000,
            "mlx-community/Llama-3.2-3B-Instruct-4bit": 1_800_000_000,
            "mlx-community/gemma-3-1b-it-qat-4bit": 800_000_000,
            "mlx-community/Phi-3.5-mini-instruct-4bit": 2_200_000_000,
            "mlx-community/SmolLM3-3B-4bit": 1_800_000_000,
            "mlx-community/LFM2-1.2B-4bit": 800_000_000,
            "mlx-community/Mistral-7B-Instruct-v0.3-4bit": 4_100_000_000,
            "mlx-community/Qwen2.5-1.5B-Instruct-4bit": 1_000_000_000,
        ]
        return sizes[id]
    }

    /// A short, chat-first slice of `LLMRegistry` — not rerankers or translators.
    static let catalog: [(id: String, name: String, note: String)] = [
        ("mlx-community/Qwen3-0.6B-4bit", "Qwen3 0.6B", "4-bit · tiny"),
        ("mlx-community/Qwen3-1.7B-4bit", "Qwen3 1.7B", "4-bit · small"),
        ("mlx-community/Qwen3-4B-4bit", "Qwen3 4B", "4-bit · default"),
        ("mlx-community/Qwen3-8B-4bit", "Qwen3 8B", "4-bit"),
        ("mlx-community/Llama-3.2-1B-Instruct-4bit", "Llama 3.2 1B", "4-bit instruct"),
        ("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B", "4-bit instruct"),
        ("mlx-community/gemma-3-1b-it-qat-4bit", "Gemma 3 1B", "QAT 4-bit"),
        ("mlx-community/Phi-3.5-mini-instruct-4bit", "Phi 3.5 Mini", "4-bit instruct"),
        ("mlx-community/SmolLM3-3B-4bit", "SmolLM3 3B", "4-bit"),
        ("mlx-community/LFM2-1.2B-4bit", "LFM2 1.2B", "4-bit"),
        ("mlx-community/Mistral-7B-Instruct-v0.3-4bit", "Mistral 7B", "4-bit instruct"),
        ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "Qwen2.5 1.5B", "4-bit instruct"),
    ]

    func models(installed: Bool) -> [ModelInfo] {
        installedIDs.removeAll { !Self.isMLXRepo($0) }
        persistInstalled()
        let ids = installedIDs
        if installed {
            return ids.filter { Self.isComplete($0) }.map { Self.info(id: $0, installed: true) }
        }
        let have = Set(ids)
        return Self.catalog
            .filter { !have.contains($0.id) }
            .map { Self.info(id: $0.id, installed: false, note: $0.note) }
    }

    /// Edge0 checkpoints share the Hub cache; they are not MLX weights.
    nonisolated static func isMLXRepo(_ id: String) -> Bool {
        let lower = id.lowercased()
        if Edge0Engine.tier(matching: id) != nil { return false }
        let org = lower.split(separator: "/").first.map(String.init) ?? lower
        if org == "edge0" || org.hasPrefix("edge0-") { return false }
        if lower.hasPrefix("edge0/") || lower.hasPrefix("edge0-") { return false }
        return true
    }

    static func info(id: String, installed: Bool, note: String? = nil) -> ModelInfo {
        let variant = id.split(separator: "-").last.map(String.init) ?? "mlx"
        // Installed rows report what is really on disk; catalog rows the
        // rough 4-bit weight size so the list never says "—".
        var size: Int64? = Self.catalogByteSize(for: id)
        if installed {
            let stats = hubCacheStats(for: id)
            if stats.logical > 0 { size = stats.logical }
        }
        return ModelInfo(
            modelID: id,
            variant: variant,
            arch: "mlx",
            quant: variant,
            sizeBytes: size,
            installed: installed,
            sourceKind: "mlx",
            path: cacheDirectory(for: id)?.path
        )
    }

    // MARK: Load

    /// Hub snapshot progress. `fraction` is the parent Progress overall 0…1
    /// (live during a file). `completedUnitCount` is per-file and must not
    /// be used as a byte total.
    struct Transfer: Sendable {
        var label: String
        var fraction: Double? = nil
    }

    /// Fetch weights into the Hub cache without swapping the running model.
    func download(
        id: String,
        onProgress: @escaping @MainActor (Transfer) -> Void
    ) async throws {
        onProgress(Transfer(label: "Downloading"))
        let downloader = HubBridge()
        _ = try await downloader.download(
            id: id,
            revision: "main",
            matching: ["*.safetensors", "*.json", "*.jinja"],
            useLatest: false
        ) { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                onProgress(Transfer(
                    label: "Downloading",
                    fraction: fraction.isFinite ? fraction : nil
                ))
            }
        }
        guard Self.isComplete(id) else {
            Self.purgeCache(for: id)
            throw ChatClient.APIError(message: "Download finished without a complete model.")
        }
        remember(id)
        onProgress(Transfer(label: "Installed", fraction: 1))
    }

    func load(
        id: String,
        onProgress: @escaping @MainActor (Transfer) -> Void
    ) async throws {
        if loadedID == id, container != nil { return }
        unload()
        let token = UUID()
        loadToken = token
        onProgress(Transfer(label: "Downloading weights"))

        let configuration = LLMModelFactory.shared.configuration(id: id)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: HubBridge(),
            using: TransformersLoader(),
            configuration: configuration
        ) { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                onProgress(Transfer(
                    label: "Downloading weights",
                    fraction: fraction.isFinite ? fraction : nil
                ))
            }
        }

        guard loadToken == token else { return }
        onProgress(Transfer(label: "Loading model into memory"))
        container = loaded
        loadedID = id
        remember(id)
        onProgress(Transfer(label: "Ready"))
    }

    func unload() {
        loadToken = UUID()
        session = nil
        sessionChat = nil
        sessionFed = 0
        container = nil
        loadedID = nil
        MLX.Memory.clearCache()
    }

    func resetSession() {
        session = nil
        sessionChat = nil
        sessionFed = 0
    }

    var memoryBytes: Int { MLX.Memory.activeMemory }

    func remember(_ id: String) {
        if !installedIDs.contains(id) {
            installedIDs.append(id)
            persistInstalled()
        }
    }

    /// Forget repos that never got a full weight file. Their Hub folders stay
    /// on disk: completed shards make the next pull a resume, and the Models
    /// sheet offers an explicit purge for partials.
    func sweepIncomplete() {
        installedIDs.removeAll { id in
            guard !Self.isComplete(id) else { return false }
            if loadedID == id { unload() }
            return true
        }
        persistInstalled()
    }

    func forget(_ id: String) {
        installedIDs.removeAll { $0 == id }
        persistInstalled()
        if loadedID == id { unload() }
        if let directory = Self.cacheDirectory(for: id) {
            try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        }
    }

    private func persistInstalled() {
        UserDefaults.standard.set(installedIDs, forKey: Self.installedKey)
    }

    // MARK: Generate

    func stream(
        history: [Message],
        chatID: UUID?,
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        topK: Int,
        maxTokens: Int,
        frequencyPenalty: Double,
        onEvent: @escaping @MainActor (Generation) async -> Void
    ) async throws {
        guard let container else {
            throw ChatClient.APIError(message: "No MLX model is loaded.")
        }

        var turns: [MLXLMCommon.Chat.Message] = []
        let system = Self.effectiveSystemPrompt(systemPrompt)
        for message in history where !message.text.isEmpty {
            switch message.role {
            case .user: turns.append(.user(message.text))
            case .assistant: turns.append(.assistant(message.text))
            }
        }
        if turns.last?.role == .assistant, turns.last?.content.isEmpty == true {
            turns.removeLast()
        }
        guard let last = turns.last, last.role == .user else {
            throw ChatClient.APIError(message: "Nothing to send.")
        }

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature),
            topP: Float(topP),
            topK: topK,
            frequencyPenalty: frequencyPenalty == 0 ? nil : Float(frequencyPenalty)
        )

        let fed = turns.count
        let sameChat = session != nil
            && sessionChat == chatID
            && sessionPrompt == system
            && sessionFed == fed - 1
        if !sameChat {
            session = ChatSession(container, instructions: system.isEmpty ? nil : system,
                                  generateParameters: parameters)
            sessionChat = chatID
            sessionPrompt = system
            sessionFed = 0
        }
        session?.generateParameters = parameters
        session?.instructions = system.isEmpty ? nil : system

        let stream: AsyncThrowingStream<Generation, Error>
        if sameChat {
            stream = session!.streamDetails(to: last.content)
        } else if turns.count == 1 {
            stream = session!.streamDetails(to: last.content)
        } else {
            stream = session!.streamDetails(to: turns)
        }

        for try await event in stream {
            if Task.isCancelled { break }
            await onEvent(event)
        }
        if !Task.isCancelled {
            sessionFed = fed
        }
    }

    /// Small MLX instruct models often dump plaintext unless they are told to
    /// use GitHub-flavored Markdown — BaseRT's converted weights already do.
    /// The formatting rule is the app's, not the user's, so it is appended to
    /// a custom system prompt too unless that prompt already asks for Markdown.
    private static let markdownRules =
        "Write replies in GitHub-flavored Markdown. Use fenced code blocks with a language tag, for example:\n\n```python\nprint(\"hello\")\n```\n\nUse headings, lists, and tables where they help."

    private static func effectiveSystemPrompt(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "You are a helpful assistant. " + markdownRules
        }
        if trimmed.localizedCaseInsensitiveContains("markdown") { return trimmed }
        return trimmed + "\n\n" + markdownRules
    }

    // MARK: Hub cache

    /// Directory that holds a downloaded snapshot, if any.
    nonisolated static func cacheDirectory(for id: String) -> URL? {
        let slug = "models--" + id.replacingOccurrences(of: "/", with: "--")
        for root in hubRoots() {
            let folder = root.appendingPathComponent(slug, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        return nil
    }

    /// A Hub snapshot is only "installed" when config and at least one real
    /// weight file are present, every shard named by the safetensors index has
    /// landed, and no `.incomplete` blobs remain. Without the index check a
    /// cancelled multi-shard pull (some shards done, none in flight) passes
    /// for complete and shows up as installed.
    nonisolated static func isComplete(_ id: String) -> Bool {
        let fm = FileManager.default
        guard let snap = hubSnapshot(for: id) else { return false }
        guard fm.fileExists(atPath: snap.appendingPathComponent("config.json").path) else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: snap.path)) ?? []
        let weights = names.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".safetensors") || lower.hasSuffix(".gguf") || lower.hasSuffix(".npz")
        }
        guard !weights.isEmpty else { return false }
        for name in weights {
            guard realWeightFile(at: snap.appendingPathComponent(name)) else { return false }
        }
        for name in requiredShards(in: snap) ?? [] {
            guard names.contains(name),
                  realWeightFile(at: snap.appendingPathComponent(name))
            else { return false }
        }
        if let blobs = cacheDirectory(for: id)?.appendingPathComponent("blobs"),
           let blobNames = try? fm.contentsOfDirectory(atPath: blobs.path),
           blobNames.contains(where: { $0.hasSuffix(".incomplete") }) {
            return false
        }
        return true
    }

    /// The shard file names listed in `model.safetensors.index.json`, if the
    /// snapshot has one. Single-file models have no index and need none.
    nonisolated static func requiredShards(in snapshot: URL) -> Set<String>? {
        let indexURL = snapshot.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String]
        else { return nil }
        return Set(weightMap.values)
    }

    /// Exists past the snapshot symlink and holds more than a stub.
    nonisolated private static func realWeightFile(at url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return false }
        let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size >= 1_000_000
    }

    /// Bytes of an unfinished Hub download — non-nil only while a repo folder
    /// exists that is not a complete model. Drives the Resume row.
    nonisolated static func partialBytes(for id: String) -> Int64? {
        guard cacheDirectory(for: id) != nil, !isComplete(id) else { return nil }
        let stats = hubCacheStats(for: id)
        return stats.allocated > 0 ? stats.allocated : nil
    }

    /// Delete an incomplete Hub repo so it cannot show up as installed.
    nonisolated static func purgeCache(for id: String) {
        let slug = "models--" + id.replacingOccurrences(of: "/", with: "--")
        let fm = FileManager.default
        for root in hubRoots() {
            let folder = root.appendingPathComponent(slug)
            if fm.fileExists(atPath: folder.path) {
                try? fm.removeItem(at: folder)
            }
        }
        if let repo = Repo.ID(rawValue: id) {
            let folder = HubCache.default.repoDirectory(repo: repo, kind: .model)
            if fm.fileExists(atPath: folder.path) {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// The snapshot folder that actually contains `config.json`.
    nonisolated static func hubSnapshot(for id: String) -> URL? {
        guard let root = cacheDirectory(for: id) else { return nil }
        let snaps = root.appendingPathComponent("snapshots")
        let fm = FileManager.default
        let revs = (try? fm.contentsOfDirectory(atPath: snaps.path)) ?? []
        for rev in revs {
            let dir = snaps.appendingPathComponent(rev)
            if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
                return dir
            }
        }
        if fm.fileExists(atPath: root.appendingPathComponent("config.json").path) {
            return root
        }
        return nil
    }

    nonisolated private static func hubRoots() -> [URL] {
        var roots: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches.appendingPathComponent("huggingface/hub"))
        }
        return roots
    }

    /// Bytes in the Hub blob cache for this repo. `allocated` is what has
    /// actually landed; `logical` is the sparse/preallocated target.
    nonisolated static func hubCacheStats(for id: String) -> (allocated: Int64, logical: Int64) {
        let slug = "models--" + id.replacingOccurrences(of: "/", with: "--")
        var roots = hubRoots().map { $0.appendingPathComponent(slug).appendingPathComponent("blobs") }
        if let repo = Repo.ID(rawValue: id) {
            roots.append(HubCache.default.blobsDirectory(repo: repo, kind: .model))
        }
        var seen = Set<String>()
        var allocated: Int64 = 0
        var logical: Int64 = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        for root in roots {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
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

    /// URLSession download tasks grow `CFNetworkDownload_*.tmp` (and Hub's
    /// `hf-download-*.tmp`) until a shard is moved into `blobs/`.
    nonisolated static func inflightDownloadBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        var sum: Int64 = 0
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("CFNetworkDownload") || name.hasPrefix("hf-download")
                    || name.hasPrefix("NSURLSession")
            else { continue }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true
            else { continue }
            if let modified = values.contentModificationDate, modified < cutoff { continue }
            sum += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return sum
    }

    /// Sum of Hub blob sizes for the files `download` actually fetches.
    /// LFS files store the real size under `lfs.size`; `size` alone is often
    /// the tiny pointer, which is what produced "809 KB of 1 MB".
    static func expectedDownloadBytes(for id: String, extraSuffixes: [String] = []) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]]
        else { return nil }
        let suffixes = [".safetensors", ".json", ".jinja"] + extraSuffixes
        let total = siblings.reduce(Int64(0)) { sum, file in
            let name = ((file["rfilename"] as? String) ?? "").lowercased()
            guard suffixes.contains(where: { name.hasSuffix($0) }) else { return sum }
            let lfs = file["lfs"] as? [String: Any]
            let size = int64(lfs?["size"]) ?? int64(file["size"]) ?? 0
            return sum + size
        }
        // A tokenizer JSON is ~1 MB. That is not the model.
        return total >= 10_000_000 ? total : nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let int as Int: return Int64(int)
        case let int as Int64: return int
        default: return nil
        }
    }

    /// Repos already on disk (from a previous MLX app, or our own pulls).
    private static func mergeCached(with known: [String]) -> [String] {
        var seen = Set(known)
        var ids = known
        let fm = FileManager.default
        for root in hubRoots() {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries where entry.hasPrefix("models--") {
                let rest = String(entry.dropFirst("models--".count))
                guard let sep = rest.range(of: "--") else { continue }
                let id = String(rest[..<sep.lowerBound]) + "/" + String(rest[sep.upperBound...])
                guard isMLXRepo(id), isComplete(id) else { continue }
                let snapshot = root
                    .appendingPathComponent(entry)
                    .appendingPathComponent("snapshots")
                guard let revs = try? fm.contentsOfDirectory(atPath: snapshot.path),
                      revs.contains(where: { rev in
                          let dir = snapshot.appendingPathComponent(rev)
                          return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
                      })
                else { continue }
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        return ids
    }

    private static func tuneMemory() {
        // Recycle GPU buffers instead of growing the working set without bound.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }
}
