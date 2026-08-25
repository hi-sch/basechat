import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @Environment(Runtime.self) private var runtime
    @Environment(SearchModel.self) private var search
    @Environment(LocalServer.self) private var localServer
    @State private var showModels = false
    @State private var showLocalServer = false

    var body: some View {
        chrome
            // While the endpoint is up the app is being driven from outside;
            // the curtain and the settings sheet are attached after this, so
            // they stay live when everything under them stops taking clicks.
            .disabled(localServer.isRunning)
            .sheet(isPresented: $showLocalServer) {
                LocalServerSheet()
            }
            .overlay {
                if localServer.isRunning {
                    LocalServerCurtain(server: localServer)
                }
            }
            .background(TitlebarPin())
            .task { await runtime.bootstrap() }
    }

    private var chrome: some View {
        @Bindable var store = store

        return NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(visibleChats) { chat in
                    ChatRow(chat: chat, term: search.isActive ? search.term : "")
                        .tag(chat.id)
                        .help(chat.lastActivity.formatted(date: .abbreviated, time: .shortened))
                        .contextMenu {
                            Button(deleteLabel(for: chat), role: .destructive) {
                                store.delete(targets(including: chat))
                            }
                        }
                }
                if search.isActive, visibleChats.isEmpty {
                    Text("No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 270, max: 380)
            .onDeleteCommand { store.delete(store.selection) }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { store.newChat() } label: {
                        Label("New Chat", systemImage: "pencil")
                    }
                    .help("New chat")
                }
            }
        } detail: {
            ChatView(showModels: $showModels, showLocalServer: $showLocalServer)
        }
        .sheet(isPresented: $showModels) {
            ModelsSheet()
        }
    }

    /// While searching the sidebar becomes a result list, Notes-style.
    private var visibleChats: [Chat] {
        guard search.isActive else { return store.chats }
        let term = search.term
        let pool = search.scope == .thisChat
            ? store.chats.filter { $0.id == store.currentID }
            : store.chats
        return pool.filter { SearchIndex.matchCount($0, term: term) > 0 }
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
    @Environment(Dictation.self) private var dictation
    @Environment(AnnotationState.self) private var annotations
    @Environment(SearchModel.self) private var search
    @Environment(DocumentLayout.self) private var layout
    @Binding var showModels: Bool
    @Binding var showLocalServer: Bool

    @AppStorage("pagedLayout") private var paged = true

    @State private var draft = ""
    @State private var draftBeforeDictation = ""
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
            // The toolbar draws itself flat while the scroll view is at its top
            // and picks up its material once content passes under it. The
            // document starts *under* the header here, so the flat state is
            // never the one to show — ask for the background outright.
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .onDeleteCommand(perform: deleteSelectedAnnotation)
            .deleteMarkupKey(annotations, perform: deleteSelectedAnnotation)
            .onExitCommand {
                // An open-but-empty field still counts: Escape closes the field
                // exactly like its own x button.
                if search.visible { search.exit() } else { annotations.arm(.none) }
            }
            // Every hit in the open chat, so ↩ can walk them and the document
            // can bring each one into view.
            .onChange(of: search.term) { _, _ in indexMatches() }
            .onChange(of: search.visible) { _, _ in indexMatches() }
            .onChange(of: store.currentID) { _, _ in indexMatches() }
    }

    private func indexMatches() {
        guard search.isActive, let chat = store.current else {
            search.setMatches([])
            return
        }
        var found: [SearchModel.Match] = []
        for message in chat.messages {
            let count = SearchIndex.ranges(in: message.text, term: search.term).count
            for ordinal in 0..<count {
                found.append(SearchModel.Match(message: message.id, ordinal: ordinal))
            }
        }
        search.setMatches(found)
    }

    private var messages: [Message] { store.current?.messages ?? [] }
    private var term: String { search.isActive ? search.term : "" }

    @ViewBuilder
    private var transcript: some View {
        if paged {
            PagedTranscript(
                chat: store.current,
                layout: layout,
                highlight: term,
                state: annotations,
                onRegenerate: regenerate,
                onOpenInPages: openInPages,
                onCreate: { annotation in
                    guard let id = store.currentID else { return }
                    store.add(annotation, to: id)
                },
                onUpdate: { annotation in
                    guard let id = store.currentID else { return }
                    store.update(annotation, in: id)
                },
                onDelete: { annotationID in
                    guard let id = store.currentID else { return }
                    store.removeAnnotation(annotationID, in: id)
                },
                focus: search.currentMatch?.message,
                focusToken: search.jump
            )
        } else {
            ContinuousTranscript(messages: messages,
                                 highlight: term,
                                 onRegenerate: regenerate,
                                 onOpenInPages: openInPages,
                                 focus: search.currentMatch?.message,
                                 focusToken: search.jump)
        }
    }

    // MARK: Composer

    private var composerBar: some View {
        VStack(spacing: 6) {
            if let note = dictationNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
            }
            GlassEffectContainer(spacing: 14) {
                HStack(alignment: .bottom, spacing: 10) {
                    formatMenu
                    micButton
                    editor
                    sendButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                // An opaque plate directly behind the glass, so it samples the
                // window rather than whichever sheet happens to be under it —
                // otherwise the bar washes out to white over the paper.
                .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 22))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
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

    /// Live speech-to-text. Pulses while the analyzer is listening.
    private var micButton: some View {
        Button(action: toggleDictation) {
            DictationIcon()
                // Only recording tints it; otherwise it matches the style menu.
                .foregroundStyle(dictation.phase.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .symbolEffect(.pulse, isActive: dictation.phase.isActive)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .padding(.leading, -4)
        .disabled(!runtime.status.isReady || !Dictation.isSupported)
        .help(dictation.phase.isActive ? "Stop dictation" : "Dictate")
    }

    private var dictationNote: String? {
        switch dictation.phase {
        case .preparing: return "Preparing dictation…"
        case .installing(let fraction): return "Downloading speech model — \(Int(fraction * 100))%"
        case .listening: return "Listening… tap the mic to stop"
        case .failed(let message): return message
        case .idle: return nil
        }
    }

    private func toggleDictation() {
        if dictation.phase.isActive {
            Task {
                _ = await dictation.stop()
                dictation.clear()
                composer.focus()
            }
        } else {
            draftBeforeDictation = draft
            dictation.clear()
            Task { await dictation.start() }
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
            MarkdownEditor(text: $draft, height: $composerHeight, controller: composer,
                           onSubmit: send,
                           onFocus: { annotations.clearSelection() })
                .frame(height: composerHeight)
        }
        .frame(minHeight: 21)
        .padding(.vertical, 3)
        .disabled(!runtime.status.isReady)
        .onChange(of: dictation.transcript) { _, heard in
            guard dictation.phase.isActive else { return }
            let base = draftBeforeDictation.trimmingCharacters(in: .whitespaces)
            draft = base.isEmpty ? heard : (heard.isEmpty ? base : base + " " + heard)
        }
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
            Pill {
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
                    HStack(spacing: 5) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 12, weight: .medium))
                        Text(modelLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 4)
                .help("Model")

                ToolButton(symbol: "slider.horizontal.3", help: "Model settings") {
                    showSettings.toggle()
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    ModelSettingsPopover()
                        .environment(settings)
                }
            }
        }

        ToolbarItem(placement: .principal) {
            MarkupTools(state: annotations)
                .padding(.trailing, 10)
        }

        ToolbarItem(placement: .primaryAction) {
            if search.visible {
                SearchField(search: search)
            } else {
                trailingTools
            }
        }
    }

    /// Copy plus the overflow menu — what the trailing slot shows when the
    /// search field is not up.
    private var trailingTools: some View {
        Pill {
            ToolButton(
                symbol: copiedConversation ? "checkmark" : "doc.on.doc",
                help: "Copy the whole conversation as Markdown",
                disabled: messages.isEmpty,
                action: copyConversation
            )
            PillDivider()
            Menu {
                Button {
                    guard let chat = store.current else { return }
                    PDFExport.run(for: chat, layout: layout, state: annotations)
                } label: {
                    Label("PDF Export…", systemImage: "arrow.down.document")
                }
                .disabled(messages.isEmpty)

                Button {
                    search.visible = true
                } label: {
                    Label("Search…", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)

                Button {
                    showLocalServer = true
                } label: {
                    Label("Local Server…", systemImage: "point.3.connected.trianglepath.dotted")
                }

                Divider()
                Toggle("Page Layout", isOn: $paged)
                Button("Clear Markup", role: .destructive) {
                    guard let id = store.currentID else { return }
                    for annotation in store.annotations(in: id) {
                        store.removeAnnotation(annotation.id, in: id)
                    }
                }
                .disabled(store.annotations(in: store.currentID).isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 22)
            .help("More")
        }
    }

    private func copyConversation() {
        guard let chat = store.current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chat.transcript, forType: .string)
        copiedConversation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedConversation = false
        }
    }

    /// Hands one answer to Apple Pages so it can be finished as a document.
    private func openInPages(_ message: Message) {
        PagesHandoff.open(message, title: store.current?.title ?? "Answer")
    }

    private func deleteSelectedAnnotation() {
        guard let id = store.currentID, !annotations.selected.isEmpty else { return }
        for mark in annotations.selected {
            store.removeAnnotation(mark, in: id)
        }
        annotations.clearSelection()
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
            // A new chat is a blank sheet and nothing else — no watermark on it.
            EmptyView()
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
        guard runtime.status.isReady, let chatID = store.currentID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        draftBeforeDictation = ""
        composerHeight = 21
        store.append(Message(role: .user, text: text), to: chatID)
        let history = store.chats.first { $0.id == chatID }?.messages ?? []
        stream(history: history, in: chatID)
    }

    /// Rewinds to a user turn and asks for a fresh answer from there.
    private func regenerate(from message: Message) {
        guard message.role == .user, runtime.status.isReady, let chatID = store.currentID else { return }
        streaming?.cancel()
        streaming = nil
        let history = store.truncate(chatID, after: message.id)
        guard !history.isEmpty else { return }
        stream(history: history, in: chatID)
    }

    private func stream(history: [Message], in chatID: Chat.ID) {
        guard let model = runtime.serverModelID else { return }
        errorText = nil
        // Stamp the turn with the model that is answering, so switching models
        // later leaves the older answers labelled with the model that wrote them.
        store.append(Message(role: .assistant, text: "", model: runtime.selectedModel ?? model), to: chatID)

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

// MARK: - Continuous (non-paginated) transcript

struct ContinuousTranscript: View {
    let messages: [Message]
    let highlight: String
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }
    /// The turn holding the search hit the field is parked on, plus a token
    /// that changes on every jump so the same turn can be revealed twice.
    var focus: Message.ID?
    var focusToken: Int = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Paper.rowSpacing) {
                    ForEach(messages) { message in
                        MessageBlock(message: message,
                                     highlight: highlight,
                                     onRegenerate: onRegenerate,
                                     onOpenInPages: onOpenInPages)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.last?.text) { _, _ in
                guard let last = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: focusToken) { _, _ in
                guard let focus else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(focus, anchor: .top) }
            }
        }
    }
}

// MARK: - One turn: bubble plus its metadata bar

struct MessageBlock: View {
    let message: Message
    var highlight: String = ""
    var baseSize: CGFloat = 13
    var document = false
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }

    private var ratio: CGFloat { baseSize / 13 }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3 * ratio) {
            bubble
            MessageMeta(message: message,
                        baseSize: baseSize,
                        onRegenerate: onRegenerate,
                        onOpenInPages: onOpenInPages)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60 * ratio)
                MarkdownView(text: message.text, highlight: highlight,
                             baseSize: baseSize, document: document)
                    .padding(.horizontal, 12 * ratio)
                    .padding(.vertical, 8 * ratio)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 14 * ratio))
            }
        case .assistant:
            HStack {
                Group {
                    if message.text.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        MarkdownView(text: message.text, highlight: highlight,
                                     baseSize: baseSize, document: document)
                    }
                }
                .padding(.horizontal, 12 * ratio)
                .padding(.vertical, 8 * ratio)
                .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 14 * ratio))
                Spacer(minLength: 60 * ratio)
            }
        }
    }
}

/// `2:32 PM · ⧉ ↻ Claude Opus 4.6` — the bar under every bubble.
struct MessageMeta: View {
    let message: Message
    var baseSize: CGFloat = 13
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }

    private var ratio: CGFloat { baseSize / 13 }
    private var glyph: CGFloat { baseSize - 2 }

    var body: some View {
        HStack(spacing: 6 * ratio) {
            Text(message.timeLabel + " ·")
                .font(.system(size: baseSize - 3))
                .foregroundStyle(.secondary)

            CopyButton(text: message.text, size: glyph)

            if message.role == .user {
                MetaButton(symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                           help: "Regenerate the answer from this message",
                           size: glyph) {
                    onRegenerate(message)
                }
            }

            if message.role == .assistant {
                MetaButton(symbol: "arrow.up.forward.app",
                           help: "Open this answer in Pages",
                           size: glyph) {
                    onOpenInPages(message)
                }
                if let label = message.modelLabel {
                    Text(label)
                        .font(.system(size: baseSize - 3))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4 * ratio)
    }
}

/// The system's own dictation glyph — the same template AppKit uses for audio
/// input — so the composer does not mix an SF Symbol in beside it.
struct DictationIcon: View {
    var body: some View {
        if let image = NSImage(named: NSImage.Name("NSTouchBarAudioInputTemplate")) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 13, height: 16)
        } else {
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
        }
    }
}

/// Small square affordance used in the metadata bar.
struct MetaButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: size + 6, height: size + 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Copies one message to the pasteboard.
struct CopyButton: View {
    let text: String
    var size: CGFloat = 11
    @State private var copied = false

    var body: some View {
        MetaButton(symbol: copied ? "checkmark" : "doc.on.doc",
                   help: "Copy this message",
                   size: size) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: copied)
    }
}

// MARK: - Toolbar furniture

/// A Preview-style capsule that groups a few related controls.
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 2)
    }
}

struct PillDivider: View {
    var body: some View {
        Rectangle()
            .fill(.secondary.opacity(0.28))
            .frame(width: 1, height: 15)
            .padding(.horizontal, 2)
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 22)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }
}

/// Highlight pen with its colour menu, plus shape / note / sketch — `design_insp_4`.
struct MarkupTools: View {
    @Bindable var state: AnnotationState

    var body: some View {
        HStack(spacing: 8) {
            Pill {
                ToolButton(symbol: "highlighter",
                           help: "Highlight",
                           active: state.tool == .mark(.highlight)) {
                    state.arm(.mark(.highlight))
                }
                Menu {
                    Picker("Colour", selection: $state.ink) {
                        ForEach(Annotation.Ink.allCases) { ink in
                            Label {
                                Text(ink.label)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(ink.color)
                            }
                            .tag(ink)
                        }
                    }
                    .pickerStyle(.inline)

                    Divider()
                    Button {
                        state.arm(.mark(.underline))
                    } label: {
                        Label("Underline", systemImage: "underline")
                    }
                    Button {
                        state.arm(.mark(.strikethrough))
                    } label: {
                        Label("Strike-through", systemImage: "strikethrough")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 20, height: 22)
                .help("Highlight colour and style")
            }

            Pill {
                ToolButton(symbol: "square.on.circle", help: "Shape", active: state.tool == .shape) {
                    state.arm(.shape)
                }
                ToolButton(symbol: "note.text", help: "Note", active: state.tool == .text) {
                    state.arm(.text)
                }
                ToolButton(symbol: "scribble", help: "Sketch", active: state.tool == .sketch) {
                    state.arm(.sketch)
                }
            }
        }
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


/// Reaches the `NSWindow` behind the view to hold the title bar in its scrolled
/// state. SwiftUI's toolbar modifier covers the toolbar's own background; the
/// separator under the title bar is AppKit's, and it too switches on whether a
/// scroll view is at its top — which, with the document running under the
/// header, it always is.
struct TitlebarPin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { pin(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { pin(view.window) }
    }

    private func pin(_ window: NSWindow?) {
        guard let window, window.toolbar != nil else { return }
        window.titlebarSeparatorStyle = .shadow
    }
}
