import Foundation

/// The `edge0` CLI: two MoE tiers, OpenAI-compatible `serve`.
enum Edge0Launch: Equatable {
    case binary(URL)
    case pythonModule(URL)
}

enum Edge0Engine {

    struct Tier: Identifiable, Hashable {
        let id: String
        let hub: String
        let env: String
        let name: String
        let note: String
        let sizeBytes: Int64
    }

    static let tiers: [Tier] = [
        Tier(id: "edge0-8b",
             hub: "Edge0/Edge0-8B-A1B-preview",
             env: "EDGE0_8B_MODEL",
             name: "Edge0 8B",
             note: "4-bit MoE · ~4.2 GB · ~1 GB RAM",
             sizeBytes: 4_200_000_000),
        Tier(id: "edge0-35b",
             hub: "Edge0/Edge0-35B-A3B-preview",
             env: "EDGE0_35B_MODEL",
             name: "Edge0 35B",
             note: "4-bit MoE · ~23 GB · ~3 GB RAM",
             sizeBytes: 23_000_000_000),
    ]

    static func tier(matching raw: String) -> Tier? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return tiers.first { $0.id == trimmed || $0.hub.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: Discovery

    static func locate() -> Edge0Launch? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var binaries: [URL] = [
            home.appendingPathComponent(".local/bin/edge0"),
            home.appendingPathComponent(".edge0/bin/edge0"),
            URL(fileURLWithPath: "/opt/homebrew/bin/edge0"),
            URL(fileURLWithPath: "/usr/local/bin/edge0"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                binaries.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("edge0"))
            }
        }
        if let found = binaries.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return .binary(found)
        }
        if let python = locatePython(withModule: "edge0") {
            return .pythonModule(python)
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    private static func locatePython(withModule module: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var pythons: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
            home.appendingPathComponent(".venv/bin/python3"),
            home.appendingPathComponent("venv/bin/python3"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                pythons.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("python3"))
            }
        }
        var seen = Set<String>()
        for python in pythons {
            let key = python.path
            guard seen.insert(key).inserted, fm.isExecutableFile(atPath: key) else { continue }
            if pythonImports(python, module: module) { return python }
        }
        return nil
    }

    private static func pythonImports(_ python: URL, module: String) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import \(module)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: Checkpoints

    static func checkpoint(for tier: Tier) -> URL? {
        let env = ProcessInfo.processInfo.environment[tier.env]
        if let env, isCheckpoint(URL(fileURLWithPath: env)) {
            return URL(fileURLWithPath: env)
        }
        if let stored = UserDefaults.standard.string(forKey: "edge0.path.\(tier.id)"),
           isCheckpoint(URL(fileURLWithPath: stored)) {
            return URL(fileURLWithPath: stored)
        }
        if let snap = MLXEngine.hubSnapshot(for: tier.hub), MLXEngine.isComplete(tier.hub) {
            return snap
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("models/\(tier.id)"),
            home.appendingPathComponent(".edge0/models/\(tier.id)"),
            supportDirectory().appendingPathComponent(tier.id),
        ]
        return candidates.first { isCheckpoint($0) }
    }

    static func remember(_ url: URL, for tier: Tier) {
        UserDefaults.standard.set(url.path, forKey: "edge0.path.\(tier.id)")
    }

    static func forget(_ tier: Tier) {
        UserDefaults.standard.removeObject(forKey: "edge0.path.\(tier.id)")
    }

    static func isCheckpoint(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let hasWeight = names.contains { name in
            let lower = name.lowercased()
            guard lower.hasSuffix(".safetensors") || lower.hasSuffix(".gguf") else { return false }
            return realWeightFile(at: url.appendingPathComponent(name))
        }
        guard hasWeight else { return false }
        // Every shard the safetensors index names must be present — a partial
        // multi-shard pull is not a runnable checkpoint.
        for shard in MLXEngine.requiredShards(in: url) ?? [] where !names.contains(shard)
            || !realWeightFile(at: url.appendingPathComponent(shard)) {
            return false
        }
        return true
    }

    private static func realWeightFile(at url: URL) -> Bool {
        let dest = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: dest.path) else { return false }
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size >= 1_000_000
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BaseChat/edge0", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func info(for tier: Tier, installed: Bool) -> ModelInfo {
        ModelInfo(
            modelID: tier.id,
            variant: "edge0",
            arch: "edge0",
            quant: "4bit",
            sizeBytes: tier.sizeBytes,
            installed: installed,
            sourceKind: "edge0",
            path: checkpoint(for: tier)?.path
        )
    }

    static func installed() -> [ModelInfo] {
        tiers.compactMap { tier in
            guard checkpoint(for: tier) != nil else { return nil }
            return info(for: tier, installed: true)
        }
    }

    static func catalog() -> [ModelInfo] {
        tiers.compactMap { tier in
            guard checkpoint(for: tier) == nil else { return nil }
            return info(for: tier, installed: false)
        }
    }

    // MARK: Launch

    static func serveArguments(checkpoint: URL, port: UInt16) -> [String] {
        ["serve", checkpoint.path, "--host", "127.0.0.1", "--port", String(port)]
    }
}
