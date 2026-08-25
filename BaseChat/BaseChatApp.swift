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
    @State private var localServer = LocalServer()
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
                .environment(localServer)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear {
                    delegate.runtime = runtime
                    delegate.store = store
                    delegate.localServer = localServer
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

                // ⌫ for the selected markup used to live here as a menu item.
                // A `Commands` body is not a view, so it never re-read the
                // selection and the item stayed disabled — the transcript owns
                // that key now, through `deleteMarkupKey`.
            }
        }
    }
}

/// Makes sure the `basert serve` child process dies with the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: Runtime?
    var store: ChatStore?
    var localServer: LocalServer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.flush()
            localServer?.stop()
            runtime?.stopServer()
        }
    }
}
