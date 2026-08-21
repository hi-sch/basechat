import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @Environment(Runtime.self) private var runtime
    @State private var showModels = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(store.chats) { chat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(chat.dateLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(chat.subtitle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(chat.id)
                    .help(chat.lastActivity.formatted(date: .abbreviated, time: .shortened))
                    .contextMenu {
                        Button(deleteLabel(for: chat), role: .destructive) {
                            store.delete(targets(including: chat))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 380)
            .onDeleteCommand { store.delete(store.selection) }
            .toolbar {
                ToolbarItem {
                    Button { store.newChat() } label: {
                        Label("New Chat", systemImage: "pencil")
                    }
                    .help("New chat")
                }
            }
        } detail: {
            ChatView(showModels: $showModels)
        }
        .sheet(isPresented: $showModels) {
            ModelsSheet()
        }
        .task { await runtime.bootstrap() }
    }

    /// Right-clicking inside a multi-selection acts on the whole selection.
    private func targets(including chat: Chat) -> Set<Chat.ID> {
        store.selection.contains(chat.id) ? store.selection : [chat.id]
    }

    private func deleteLabel(for chat: Chat) -> String {
        let count = targets(including: chat).count
        return count > 1 ? "Delete \(count) Chats" : "Delete"
    }
}

// MARK: - Transcript + composer

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(Runtime.self) private var runtime
    @Environment(ModelSettings.self) private var settings
    @Binding var showModels: Bool

    @State private var draft = ""
    @State private var composerHeight: CGFloat = 21
    @State private var composer = ComposerController()
    @State private var streaming: Task<Void, Never>?
    @State private var errorText: String?
    @State private var copiedConversation = false
    @State private var showSettings = false

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom) { composerBar }
            .overlay { statusOverlay }
            .navigationTitle(store.current?.title ?? "BaseChat")
            .toolbar { toolbarContent }
    }

    private var messages: [Message] { store.current?.messages ?? [] }

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selection) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Composer

    private var composerBar: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                formatMenu
                editor
                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var formatMenu: some View {
        Menu {
            Section("Style") {
                ForEach([TextStyle.title, .heading, .subheading, .body], id: \.self, content: styleButton)
            }
            Section("Format") {
                ForEach([TextStyle.bold, .italic, .strikethrough, .monospaced], id: \.self, content: styleButton)
            }
            Section("Blocks") {
                ForEach([TextStyle.bulleted, .numbered, .quote, .codeBlock], id: \.self, content: styleButton)
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .padding(.bottom, 2)
        .disabled(!runtime.status.isReady)
        .help("Text style — inserts Markdown")
    }

    @ViewBuilder
    private func styleButton(_ style: TextStyle) -> some View {
        let button = Button {
            composer.apply(style)
        } label: {
            Label(style.label, systemImage: style.symbol)
        }
        if let shortcut = style.shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Message… (⌘↩ to send)")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
            }
            MarkdownEditor(text: $draft, height: $composerHeight, controller: composer, onSubmit: send)
                .frame(height: composerHeight)
        }
        .frame(minHeight: 21)
        .padding(.vertical, 3)
        .disabled(!runtime.status.isReady)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: streaming == nil ? "arrow.up" : "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(canSend ? Color.accentColor : Color.secondary.opacity(0.4), in: .circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
        .help(streaming == nil ? "Send" : "Stop")
    }

    private var canSend: Bool {
        guard runtime.status.isReady else { return false }
        return streaming != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                if runtime.installed.isEmpty {
                    Text("No models installed")
                }
                ForEach(runtime.installed) { model in
                    Button {
                        Task { await runtime.start(model: model.id) }
                    } label: {
                        if model.id == runtime.selectedModel {
                            Label("\(model.displayName) · \(model.variant)", systemImage: "checkmark")
                        } else {
                            Text("\(model.displayName) · \(model.variant)")
                        }
                    }
                }
                Divider()
                Button("Manage Models…") { showModels = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                    Text(modelLabel)
                        .padding(.horizontal, 20)
                }
                .padding(.horizontal, 12)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")
        }
        ToolbarItem(placement: .principal) {
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help("Model settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                ModelSettingsPopover()
                    .environment(settings)
            }
        }
        ToolbarItem {
            Button {
                guard let chat = store.current else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.transcript, forType: .string)
                copiedConversation = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copiedConversation = false
                }
            } label: {
                Label(copiedConversation ? "Copied" : "Copy Conversation",
                      systemImage: copiedConversation ? "checkmark" : "doc.on.doc")
            }
            .disabled(messages.isEmpty)
            .help("Copy the whole conversation as Markdown")
        }
    }

    private var modelLabel: String {
        guard let id = runtime.selectedModel else { return "No model" }
        return runtime.installed.first { $0.id == id }?.displayName ?? id
    }

    // MARK: Status

    @ViewBuilder
    private var statusOverlay: some View {
        switch runtime.status {
        case .missingBinary:
            Notice(
                icon: "exclamationmark.triangle",
                title: "BaseRT not found",
                message: "Expected the `basert` CLI at ~/.basert/basert, /opt/homebrew/bin or /usr/local/bin.",
                action: nil
            )
        case .noModels:
            Notice(
                icon: "arrow.down.circle",
                title: "No models installed",
                message: "Download one from the BaseRT catalog or any Hugging Face repo to start chatting.",
                action: ("Browse Models", { showModels = true })
            )
        case .launching(let id):
            VStack(spacing: 14) {
                LogoMark()
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                Text(runtime.loadPhase.isEmpty ? "Starting engine" : runtime.loadPhase)
                    .font(.callout.weight(.medium))
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        case .failed(let message):
            Notice(
                icon: "xmark.octagon",
                title: "Server error",
                message: message + (runtime.serverLog.isEmpty ? "" : "\n\n" + String(runtime.serverLog.suffix(600))),
                action: ("Manage Models", { showModels = true })
            )
        case .ready, .locating:
            if messages.isEmpty, runtime.status.isReady {
                VStack(spacing: 12) {
                    LogoMark()
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                    Text("Ask anything")
                        .font(.title3.weight(.semibold))
                    Text("\(modelLabel) is loaded and running locally.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Sending

    private func send() {
        if let streaming {
            streaming.cancel()
            self.streaming = nil
            store.save()
            return
        }
        guard runtime.status.isReady,
              let model = runtime.serverModelID,
              let chatID = store.currentID
        else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        composerHeight = 21
        errorText = nil
        store.append(Message(role: .user, text: text), to: chatID)
        let history = store.chats.first { $0.id == chatID }?.messages ?? []
        store.append(Message(role: .assistant, text: ""), to: chatID)

        let client = ChatClient(
            baseURL: runtime.apiURL,
            model: model,
            apiKey: runtime.apiToken,
            systemPrompt: settings.systemPrompt,
            temperature: settings.temperature,
            topP: settings.topP,
            topK: settings.topK,
            maxTokens: settings.maxTokens,
            frequencyPenalty: settings.frequencyPenalty
        )
        streaming = Task { @MainActor in
            var accumulated = ""
            do {
                try await client.send(history) { delta in
                    accumulated += delta
                    store.updateLastAssistant(in: chatID, text: accumulated)
                }
            } catch is CancellationError {
                // Keep whatever streamed in.
            } catch {
                errorText = error.localizedDescription
            }
            if accumulated.isEmpty {
                store.updateLastAssistant(in: chatID, text: "⚠️ " + (errorText ?? "No response."))
            }
            store.save()
            streaming = nil
        }
    }
}

// MARK: - Pieces

struct MessageRow: View {
    let message: Message
    @State private var hovering = false

    var body: some View {
        content
            // Without an explicit shape only the glyphs are hoverable, so the
            // pointer loses hover crossing the gap to the button.
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 60)
                CopyButton(text: message.text)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                MarkdownView(text: message.text)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.30)), in: .rect(cornerRadius: 18))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                LogoMark(lineWidth: 2)
                    .foregroundStyle(.tint)
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                if message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownView(text: message.text)
                }
                if !message.text.isEmpty {
                    CopyButton(text: message.text)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Small copy affordance that appears on hover over a message.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Copy this message")
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

struct Notice: View {
    let icon: String
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
