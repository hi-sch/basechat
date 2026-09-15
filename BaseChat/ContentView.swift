import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @Environment(Runtime.self) private var runtime
    @Environment(SearchModel.self) private var search
    @Environment(LocalServer.self) private var localServer
    @Environment(\.undoManager) private var undoManager
    @State private var showModels = false
    @State private var showLocalServer = false
    @State private var renaming: Chat.ID?

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
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await runtime.rescanEngines() }
            }
    }

    private var chrome: some View {
        @Bindable var store = store

        return NavigationSplitView {
            List(selection: $store.selection) {
                ForEach(visibleChats) { chat in
                    ChatRow(chat: chat, term: search.isActive ? search.term : "",
                            renaming: $renaming)
                        .tag(chat.id)
                        .help(chat.lastActivity.formatted(date: .abbreviated, time: .shortened))
                        .contextMenu {
                            Button("Rename") {
                                renaming = chat.id
                            }
                            Button(deleteLabel(for: chat), role: .destructive) {
                                store.delete(targets(including: chat), undoManager: undoManager)
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
            .onDeleteCommand { store.delete(store.selection, undoManager: undoManager) }
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
    @Environment(\.undoManager) private var undoManager
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
    /// The assistant turn being generated — drives the thinking fold's
    /// expand-while-thinking / collapse-on-answer cycle.
    @State private var streamingMessageID: Message.ID?
    @State private var errorText: String?
    @State private var copiedConversation = false
    @State private var showSettings = false
    /// Where the settings button sits, so its panel can hang under it like the
    /// markup tools' do.
    @State private var settingsAnchor: CGRect = .zero

    var body: some View {
        transcript
            .overlay(alignment: .topLeading) { markupOptions }
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
            .markupKeys(annotations,
                        delete: deleteSelectedAnnotation,
                        nudge: nudgeSelectedAnnotations,
                        duplicate: duplicateSelectedAnnotations)
            .onExitCommand {
                // An open-but-empty field still counts: Escape closes the field
                // exactly like its own x button. After that Escape belongs to
                // the panels and the markup, which give themselves up a layer
                // at a time.
                if search.visible {
                    search.exit()
                } else if showSettings {
                    showSettings = false
                } else {
                    _ = annotations.retreat()
                }
            }
            // A click on the page puts every header panel away, and opening a
            // tool's options closes the settings beside it.
            .onChange(of: annotations.panelDismissals) { _, _ in showSettings = false }
            .onChange(of: annotations.options) { _, open in
                if open != nil { showSettings = false }
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
            var haystack = message.text
            if let reasoning = message.reasoning { haystack += "\n" + reasoning }
            if let model = message.model { haystack += "\n" + model + "\n" + Message.prettyModel(model) }
            let count = SearchIndex.ranges(in: haystack, term: search.term).count
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
                liveMessageID: streamingMessageID,
                onRegenerate: regenerate,
                onOpenInPages: openInPages,
                onCreate: { annotation in
                    guard let id = store.currentID else { return }
                    store.add(annotation, to: id, undoManager: undoManager)
                },
                onUpdate: { annotation in
                    guard let id = store.currentID else { return }
                    store.update(annotation, in: id, undoManager: undoManager)
                },
                onDelete: { annotationID in
                    guard let id = store.currentID else { return }
                    store.removeAnnotation(annotationID, in: id, undoManager: undoManager)
                },
                focus: search.currentMatch?.message,
                focusToken: search.jump
            )
        } else {
            ContinuousTranscript(
                chat: store.current,
                highlight: term,
                state: annotations,
                liveMessageID: streamingMessageID,
                onRegenerate: regenerate,
                onOpenInPages: openInPages,
                onCreate: { annotation in
                    guard let id = store.currentID else { return }
                    store.add(annotation, to: id, undoManager: undoManager)
                },
                onUpdate: { annotation in
                    guard let id = store.currentID else { return }
                    store.update(annotation, in: id, undoManager: undoManager)
                },
                onDelete: { annotationID in
                    guard let id = store.currentID else { return }
                    store.removeAnnotation(annotationID, in: id, undoManager: undoManager)
                },
                focus: search.currentMatch?.message,
                focusToken: search.jump
            )
        }
    }

    /// The open tool's options, floating under the button that opened them.
    /// They live over the document rather than in a popover so the next click
    /// is a stroke on the page and not a dismissal.
    @ViewBuilder
    private var markupOptions: some View {
        GeometryReader { geometry in
            let here = geometry.frame(in: .global)
            if let family = annotations.options, let anchor = annotations.anchors[family] {
                UnderAnchor(anchor: anchor, container: here) {
                    ToolOptions(state: annotations, family: family)
                }
                .transition(.opacity)
            }
            if showSettings, settingsAnchor != .zero {
                UnderAnchor(anchor: settingsAnchor, container: here) {
                    ModelSettingsPanel()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: annotations.options)
        .animation(.easeOut(duration: 0.12), value: showSettings)
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
            if let error = store.persistError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
        .disabled(!Dictation.isSupported)
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
                    Picker("Engine", selection: Binding(
                        get: { runtime.engine },
                        set: { next in Task { await runtime.switchEngine(to: next) } }
                    )) {
                        ForEach(runtime.availableEngines) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    Divider()
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

                ToolButton(symbol: "slider.horizontal.3",
                           help: "Model settings",
                           active: showSettings) {
                    showSettings.toggle()
                    annotations.options = nil
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    settingsAnchor = frame
                }
            }
        }

        ToolbarItem(placement: .principal) {
            MarkupTools(state: annotations, highlightSelection: highlightTextSelection)
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
                        store.removeAnnotation(annotation.id, in: id, undoManager: undoManager)
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
            store.removeAnnotation(mark, in: id, undoManager: undoManager)
        }
        annotations.clearSelection()
    }

    /// Arrow keys. The step arrives in points on the sheet; the marks are
    /// stored in page units, so it is divided down here.
    private func nudgeSelectedAnnotations(by step: CGSize) {
        guard let id = store.currentID else { return }
        let moving = store.annotations(in: id).filter {
            annotations.isSelected($0.id) && !$0.isTextMark
        }
        guard !moving.isEmpty else { return }
        for mark in moving {
            store.update(mark.moved(dx: step.width / Paper.width, dy: step.height / Paper.height),
                         in: id, undoManager: undoManager)
        }
    }

    private func duplicateSelectedAnnotations() {
        guard let id = store.currentID else { return }
        let copies = store.annotations(in: id)
            .filter { annotations.isSelected($0.id) }
            .map { $0.duplicated() }
        guard !copies.isEmpty else { return }
        for copy in copies { store.add(copy, to: id, undoManager: undoManager) }
        annotations.selected = Set(copies.map(\.id))
    }

    /// The highlighter's other way in: mark the text the reader already
    /// selected, and say whether there was any.
    private func highlightTextSelection() -> Bool {
        guard let chat = store.current, let id = store.currentID, paged,
              let selection = TextSelectionMarkup.selectedText()
        else { return false }
        let made = TextSelectionMarkup.marks(for: selection, in: chat,
                                             layout: layout, state: annotations)
        guard !made.isEmpty else { return false }
        for mark in made { store.add(mark, to: id, undoManager: undoManager) }
        annotations.tool = .none
        annotations.options = nil
        annotations.selected = Set(made.map(\.id))
        return true
    }

    private var modelLabel: String {
        guard let id = runtime.selectedModel else { return runtime.engine.label }
        let name = runtime.installed.first { $0.id == id }?.displayName ?? id
        return "\(name) · \(runtime.engine.label)"
    }

    // MARK: Status

    @ViewBuilder
    private var statusOverlay: some View {
        switch runtime.status {
        case .missingBinary:
            Notice(
                icon: "exclamationmark.triangle",
                title: "\(runtime.engine.label) not found",
                message: runtime.engine == .edge0
                    ? "Install the edge0 CLI (`pip install -e git+https://github.com/Edge0-AI/edge0.git#egg=edge0`) or switch engine."
                    : "Expected the `basert` CLI at ~/.basert/basert, /opt/homebrew/bin or /usr/local/bin. MLX runs in-process with no extra install.",
                action: runtime.availableEngines.contains(.mlx)
                    ? ("Use MLX instead", {
                        Task { await runtime.switchEngine(to: .mlx) }
                        return
                    })
                    : nil
            )
        case .noModels:
            Notice(
                icon: "arrow.down.circle",
                title: "No models installed",
                message: {
                    switch runtime.engine {
                    case .edge0: return "Download Edge0 8B (~4.2 GB) or Edge0 35B (~23 GB) from the catalog. They are the two tiers the edge0 runtime ships."
                    case .mlx: return "Download an MLX model from Hugging Face — Qwen3 4B is a good start on Apple silicon."
                    case .basert: return "Download one from the BaseRT catalog or any Hugging Face repo to start chatting."
                    }
                }(),
                action: ("Browse Models", { showModels = true })
            )
        case .launching(let id):
            if runtime.loadPhase == "Ready" {
                EmptyView()
            } else {
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
                if let ram = runtime.memoryLabel {
                    Text(ram + " GPU")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let speed = runtime.lastTokensPerSecond, speed > 0 {
                    Text(String(format: "%.1f tok/s last reply", speed))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
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
            runtime.mlx.resetSession()
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
        runtime.mlx.resetSession()
        let history = store.truncate(chatID, after: message.id)
        guard !history.isEmpty else { return }
        stream(history: history, in: chatID)
    }

    private func stream(history: [Message], in chatID: Chat.ID) {
        guard runtime.status.isReady else { return }
        errorText = nil
        // Stamp the turn with the model that is answering, so switching models
        // later leaves the older answers labelled with the model that wrote them.
        let model = runtime.selectedModel ?? runtime.serverModelID
        store.append(Message(role: .assistant, text: "", model: model), to: chatID)
        streamingMessageID = store.chats.first { $0.id == chatID }?.messages.last?.id

        streaming = Task { @MainActor in
            var accumulated = ""
            var deltas = 0
            do {
                let info = try await runtime.complete(
                    history: history,
                    chatID: chatID,
                    systemPrompt: settings.systemPrompt,
                    temperature: settings.temperature,
                    topP: settings.topP,
                    topK: settings.topK,
                    maxTokens: settings.maxTokens,
                    frequencyPenalty: settings.frequencyPenalty,
                    onDelta: { delta in
                        accumulated += delta
                        store.updateLastAssistant(in: chatID, text: accumulated)
                        deltas += 1
                        if deltas.isMultiple(of: 32) { store.save() }
                    },
                    onReasoning: { chunk in
                        store.updateLastAssistant(in: chatID, reasoning: chunk)
                    }
                )
                store.updateLastAssistant(
                    in: chatID,
                    tokensPerSecond: info.tokensPerSecond,
                    contextTrimmed: info.trimmed
                )
            } catch is CancellationError {
                // Keep whatever streamed in.
            } catch {
                errorText = error.localizedDescription
            }
            if accumulated.isEmpty {
                store.updateLastAssistant(in: chatID, text: "⚠️ " + (errorText ?? "No response."))
            }
            store.save()
            streamingMessageID = nil
            streaming = nil
        }
    }
}

// MARK: - Continuous (non-paginated) transcript

struct ContinuousTranscript: View {
    @Environment(\.colorScheme) private var appearance
    let chat: Chat?
    let highlight: String
    let state: AnnotationState
    /// The assistant turn being generated — nil outside a live chat.
    var liveMessageID: Message.ID?
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }
    var onCreate: (Annotation) -> Void = { _ in }
    var onUpdate: (Annotation) -> Void = { _ in }
    var onDelete: (Annotation.ID) -> Void = { _ in }
    var focus: Message.ID?
    var focusToken: Int = 0

    private var messages: [Message] { chat?.messages ?? [] }
    private var markupLive: Bool { state.tool.isDrawing || !(chat?.annotations.isEmpty ?? true) }

    var body: some View {
        GeometryReader { geometry in
            let width = min(780, geometry.size.width) - 48
            ScrollViewReader { proxy in
                ScrollView {
                    messageStack(width: width)
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

    @ViewBuilder
    private func messageStack(width: CGFloat) -> some View {
        let content = ForEach(messages) { message in
            MessageBlock(message: message,
                         highlight: highlight,
                         live: true,
                         liveMessageID: liveMessageID,
                         onRegenerate: onRegenerate,
                         onOpenInPages: onOpenInPages)
                .id(message.id)
        }
        if markupLive {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Paper.rowSpacing) { content }
                continuousMarkup(width: width)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: Paper.rowSpacing) { content }
        }
    }

    private func continuousMarkup(width: CGFloat) -> some View {
        var y: CGFloat = 0
        var columns: [TextColumn] = []
        let scale = max(width * 4, 1)
        for message in messages {
            let raw = InkMap.lines(of: message, width: width, liveMessageID: liveMessageID)
            let lines = raw.map { line in
                CGRect(x: line.minX / width,
                       y: (y + line.minY) / scale,
                       width: line.width / width,
                       height: line.height / scale)
            }
            let block = raw.last.map { y + $0.maxY } ?? (y + 40)
            columns.append(TextColumn(
                rect: CGRect(x: 0, y: y / scale, width: 1, height: max(block - y, 40) / scale),
                lines: lines
            ))
            y = block + Paper.rowSpacing
        }
        let height = max(y, 400)
        return AnnotationLayer(
            page: 0,
            size: CGSize(width: width, height: height),
            annotations: chat?.annotations ?? [],
            state: state,
            columns: columns,
            live: true,
            appearance: appearance,
            scale: 1,
            onCreate: onCreate,
            onUpdate: onUpdate,
            onDelete: onDelete
        )
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(state.tool.isDrawing || !state.selected.isEmpty)
    }
}

// MARK: - One turn: bubble plus its metadata bar

struct MessageBlock: View {
    let message: Message
    var highlight: String = ""
    var baseSize: CGFloat = 13
    var document = false
    /// On screen (paper or continuous) vs. a static export. Only a live view
    /// follows the thinking fold's expand/collapse cycle; a PDF pins it open.
    var live = false
    /// The assistant turn currently being generated, if any.
    var liveMessageID: Message.ID?
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }

    private var ratio: CGFloat { baseSize / 13 }

    /// True only while this turn is the one streaming and no answer text has
    /// arrived yet — i.e. while the model is still thinking.
    private var isThinking: Bool {
        live && message.id == liveMessageID && message.text.isEmpty
    }

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
                VStack(alignment: .leading, spacing: 8 * ratio) {
                    if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ThinkingFold(
                            text: reasoning,
                            highlight: highlight,
                            baseSize: baseSize,
                            document: document,
                            live: live,
                            streaming: isThinking
                        )
                    }
                    if message.text.isEmpty {
                        if live && message.id == liveMessageID,
                           message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        MarkdownView(text: message.text, highlight: highlight,
                                     baseSize: baseSize, document: document)
                    }
                    if message.contextTrimmed {
                        Text("Earlier turns were trimmed to fit the context window.")
                            .font(.system(size: baseSize - 3))
                            .foregroundStyle(.tertiary)
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

/// Disclosure-style fold. Forced open while the answer has not started
/// (spinner on the label). At most 16 lines, with a scrollbar; new tokens
/// pin the scroller to the bottom like the chat transcript. Collapses when
/// the visible reply begins. A static export (`document`, not `live`) pins
/// it open with no scroller — the paper shows the whole trace.
private struct ThinkingFold: View {
    let text: String
    var highlight: String = ""
    var baseSize: CGFloat = 13
    var document = false
    var live = false
    var streaming = false
    @State private var expanded = true

    private var fontSize: CGFloat { max(baseSize - 1, 11) }
    private var boxHeight: CGFloat { fontSize * 1.35 * 16 }
    private var pinnedOpen: Bool { document && !live }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { pinnedOpen || streaming || expanded },
            set: { newValue in
                if !streaming { expanded = newValue }
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            let body = MarkdownView(text: text, highlight: highlight,
                                    baseSize: fontSize, document: document)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if pinnedOpen {
                body
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            body
                            Color.clear.frame(height: 1).id("thinking-tail")
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: boxHeight)
                    .onChange(of: text) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("thinking-tail", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("thinking-tail", anchor: .bottom)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if streaming, !document {
                    ProgressView().controlSize(.mini)
                }
                Text(streaming ? "Thinking…" : "Thinking")
            }
            .font(.system(size: baseSize - 2, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .onChange(of: streaming) { _, isStreaming in
            if pinnedOpen { return }
            expanded = isStreaming
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
                if let speed = message.tokensPerSecond, speed > 0 {
                    Text(String(format: "· %.1f tok/s", speed))
                        .font(.system(size: baseSize - 3))
                        .foregroundStyle(.tertiary)
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
