import SwiftUI

struct ModelsSheet: View {
    @Environment(Runtime.self) private var runtime
    @Environment(\.dismiss) private var dismiss

    @State private var repoID = ""
    @State private var target = "base-q4"
    @State private var loadingCatalog = false
    @State private var pendingDelete: ModelInfo?

    private let targets = ["base-q2", "base-q3", "base-q4", "base-q5", "base-q6", "base-q8", "bf16", "mxfp4", "nvfp4"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                downloadSection
                if !runtime.installed.isEmpty { installedSection }
                catalogSection
            }
            .listStyle(.inset)

            if runtime.pullingID != nil || !runtime.pullLog.isEmpty {
                Divider()
                progressPane
            }
        }
        .frame(width: 640, height: 580)
        .task {
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(lineWidth: 2)
                .foregroundStyle(.tint)
                .frame(width: 18, height: 18)
            Text("Models").font(.headline)
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
                TextField("org/model  (e.g. Qwen/Qwen3-4B)", text: $repoID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startPull)
                Picker("", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Download", action: startPull)
                    .buttonStyle(.glass)
                    .disabled(runtime.pullingID != nil || repoID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Any Hugging Face repo is downloaded and converted to `.base` locally. `basecompute/…` ids come pre-converted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        Section("Installed") {
            ForEach(runtime.installed) { model in
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
        Section("BaseRT Catalog") {
            if loadingCatalog {
                HStack { ProgressView().controlSize(.small); Text("Loading catalog…").foregroundStyle(.secondary) }
            } else if runtime.catalog.isEmpty {
                Text("Everything in the catalog is installed.").foregroundStyle(.secondary)
            }
            ForEach(runtime.catalog) { model in
                HStack {
                    row(model)
                    Spacer()
                    Button("Get") {
                        Task { await runtime.pull(id: model.modelID, target: nil) }
                    }
                    .buttonStyle(.glass)
                    .disabled(runtime.pullingID != nil)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName).font(.body)
            Text([model.modelID, model.variant, model.sizeText].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                    Text(byteLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let expected = runtime.pullExpected, expected > 0 {
                    ProgressView(value: min(Double(runtime.pullReceived), Double(expected)), total: Double(expected))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            } else {
                Text(runtime.pullPhase.isEmpty ? "Log" : runtime.pullPhase)
                    .font(.callout.weight(.medium))
            }

            ScrollView {
                Text(runtime.pullLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 92)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
    }

    private var byteLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: runtime.pullReceived)
        if let expected = runtime.pullExpected, expected > 0 {
            return "\(received) of \(formatter.string(fromByteCount: expected))"
        }
        return received
    }

    private func startPull() {
        let id = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        Task { await runtime.pull(id: id, target: target) }
    }
}
