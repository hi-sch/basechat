import SwiftUI

@main
struct BaseChatApp: App {
    @State private var store = ChatStore()
    @State private var runtime = Runtime()
    @State private var settings = ModelSettings()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(runtime)
                .environment(settings)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear { delegate.runtime = runtime }
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// Makes sure the `basert serve` child process dies with the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: Runtime?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { runtime?.stopServer() }
    }
}
