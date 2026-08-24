import SwiftUI

@main
struct BaseChatApp: App {
    @State private var store = ChatStore()
    @State private var runtime = Runtime()
    @State private var settings = ModelSettings()
    @State private var dictation = Dictation()
    @State private var markup = AnnotationState()
    @State private var search = SearchModel()
    @State private var layout = DocumentLayout()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(runtime)
                .environment(settings)
                .environment(dictation)
                .environment(markup)
                .environment(search)
                .environment(layout)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear {
                    delegate.runtime = runtime
                    delegate.store = store
                }
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { search.open() }
                    .keyboardShortcut("f", modifiers: .command)

                // Delete only binds while a mark is selected and no note is
                // being typed in, and the composer drops the selection as soon
                // as the caret lands there, so ordinary editing keeps its key.
                Button("Delete Markup") {
                    guard let chat = store.currentID, let mark = markup.selection else { return }
                    store.removeAnnotation(mark, in: chat)
                    markup.selection = nil
                    markup.editing = nil
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(markup.selection == nil || markup.editing != nil)
            }
        }
    }
}

/// Makes sure the `basert serve` child process dies with the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: Runtime?
    var store: ChatStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.flush()
            runtime?.stopServer()
        }
    }
}
