import SwiftUI

struct ModelsSheet: View {
    @Environment(Runtime.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    @State private var repoID = ""
    @State private var target = "base-q4"
    @State private var loadingCatalog = false
    @State private var pendingDelete: ModelInfo?
    @State private var pendingDiscard: ModelInfo?

    private let targets = ["base-q2", "base-q3", "base-q4", "base-q5", "base-q6", "base-q8", "bf16", "mxfp4", "nvfp4"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                downloadSection
                if !visibleModels(runtime.installed).isEmpty { installedSection }
                catalogSection
            }
            .listStyle(.inset)

            if runtime.pullingID != nil || !runtime.pullLog.isEmpty {
                Divider()
                progressPane
            }
        }
        .frame(width: 640, height: 580)
        .task(id: runtime.engine) {
            await runtime.rescanEngines()
            loadingCatalog = true
            await runtime.refreshInstalled()
            await runtime.refreshCatalog()
            loadingCatalog = false
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let model = pendingDelete {
                    pendingDelete = nil
                    Task { await runtime.delete(model) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("\(pendingDelete?.sizeText ?? "") will be moved to the Trash. You can put it back from there.")
        }
        .confirmationDialog(
            "Discard partial download?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
        ) {
            Button("Discard", role: .destructive) {
                if let model = pendingDiscard {
                    pendingDiscard = nil
                    Task { await runtime.discardPartial(model.modelID) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("The \(pendingDiscard.map { partialText(for: $0) } ?? "") already downloaded will be deleted. The next download starts from zero.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(lineWidth: 2)
                .foregroundStyle(.tint)
                .frame(width: 18, height: 18)
            Text("Models").font(.headline)
            Picker("Engine", selection: Binding(
                get: { runtime.engine },
                set: { next in Task { await runtime.switchEngine(to: next) } }
            )) {
                ForEach(runtime.availableEngines) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 180, maxWidth: 260)
            .help(runtime.engine.help)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var downloadSection: some View {
        Section("Download from Hugging Face") {
            HStack(spacing: 8) {
                TextField({
                    switch runtime.engine {
                    case .edge0: return "edge0-8b or Edge0/Edge0-8B-A1B-preview"
                    case .mlx: return "mlx-community/Qwen3-4B-4bit"
                    case .basert: return "org/model  (e.g. Qwen/Qwen3-4B)"
                    }
                }(), text: $repoID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startPull)
                if runtime.engine == .basert {
                    Picker("", selection: $target) {
                        ForEach(targets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Button("Download", action: startPull)
                    .buttonStyle(.glass)
                    .disabled(runtime.pullingID != nil || repoID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text({
                switch runtime.engine {
                case .edge0:
                    return "Edge0 8B and 35B are the two supported tiers. Each Hub repo is a ready-to-run checkpoint (base + LoRA + prerouter)."
                case .mlx:
                    return "Any Hugging Face repo with MLX safetensors (typically mlx-community/…). Weights stay on this Mac."
                case .basert:
                    return "Any Hugging Face repo is downloaded and converted to `.base` locally. `basecompute/…` ids come pre-converted."
                }
            }())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        Section("Installed") {
            ForEach(visibleModels(runtime.installed)) { model in
                HStack {
                    row(model)
                    Spacer()
                    if model.id == runtime.selectedModel {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    } else {
                        Button("Use") {
                            Task { await runtime.start(model: model.id) }
                        }
                        .buttonStyle(.glass)
                    }
                    Button {
                        pendingDelete = model
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(runtime.pullingID != nil)
                    .help("Move this model to the Trash")
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section({
            switch runtime.engine {
            case .edge0: return "Edge0 Catalog"
            case .mlx: return "MLX Catalog"
            case .basert: return "BaseRT Catalog"
            }
        }()) {
            if loadingCatalog {
                HStack { ProgressView().controlSize(.small); Text("Loading catalog…").foregroundStyle(.secondary) }
            } else if visibleModels(runtime.catalog).isEmpty {
                Text({
                    switch runtime.engine {
                    case .edge0: return "Both Edge0 tiers are installed."
                    case .mlx: return "Everything in the catalog is installed — paste any mlx-community id above."
                    case .basert: return "Everything in the catalog is installed."
                    }
                }())
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleModels(runtime.catalog)) { model in
                HStack {
                    row(model)
                    Spacer()
                    // A half-finished Hub download resumes where it stopped:
                    // completed shards are already in the blob cache.
                    if partialBytes(for: model) != nil {
                        Button("Resume") {
                            Task { await runtime.pull(id: model.modelID, target: nil) }
                        }
                        .buttonStyle(.glass)
                        .disabled(runtime.pullingID != nil)
                        Button {
                            pendingDiscard = model
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(runtime.pullingID != nil)
                        .help("Discard the partial download")
                    } else {
                        Button("Get") {
                            Task { await runtime.pull(id: model.modelID, target: nil) }
                        }
                        .buttonStyle(.glass)
                        .disabled(runtime.pullingID != nil)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName).font(.body)
            Text({
                var parts: [String]
                if model.sourceKind == "edge0", let tier = Edge0Engine.tier(matching: model.modelID) {
                    parts = [tier.hub, tier.note]
                } else {
                    parts = [model.modelID, model.variant, model.sizeText]
                }
                if let bytes = partialBytes(for: model) {
                    parts.append("Partial · \(Self.bytes.string(fromByteCount: bytes)) downloaded")
                }
                return parts.joined(separator: " · ")
            }())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Partial downloads

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Edge0 rows download their tier's Hub repo; everything else is its own id.
    private func hubID(_ model: ModelInfo) -> String {
        Edge0Engine.tier(matching: model.modelID)?.hub ?? model.modelID
    }

    private func partialBytes(for model: ModelInfo) -> Int64? {
        guard runtime.engine != .basert else { return nil }
        return MLXEngine.partialBytes(for: hubID(model))
    }

    private func partialText(for model: ModelInfo) -> String {
        guard let bytes = partialBytes(for: model) else { return "files" }
        return Self.bytes.string(fromByteCount: bytes)
    }

    // MARK: Progress

    private var progressPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = runtime.pullingID {
                HStack {
                    Text(runtime.pullPhase.isEmpty ? "Working" : runtime.pullPhase)
                        .font(.callout.weight(.medium))
                    Text(id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(runtime.pullSizeLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel") { runtime.cancelPull() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if runtime.pullShownExpected != nil || runtime.pullFraction > 0 {
                    ProgressView(value: min(max(runtime.pullFraction, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            } else {
                Text(runtime.pullPhase.isEmpty ? "Log" : runtime.pullPhase)
                    .font(.callout.weight(.medium))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runtime.pullLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("log")
                }
                .onChange(of: runtime.pullLog) { _, _ in
                    proxy.scrollTo("log", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("log", anchor: .bottom) }
            }
            .frame(height: 92)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
    }

    private func visibleModels(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { model in
            switch runtime.engine {
            case .mlx:
                return model.sourceKind != "edge0" && MLXEngine.isMLXRepo(model.modelID)
            case .edge0:
                return model.sourceKind == "edge0" || Edge0Engine.tier(matching: model.modelID) != nil
            case .basert:
                return model.sourceKind != "edge0" && model.sourceKind != "mlx"
            }
        }
    }

    private func startPull() {
        let id = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        Task { await runtime.pull(id: id, target: target) }
    }
}
