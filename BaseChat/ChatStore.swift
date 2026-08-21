import Foundation
import Observation

/// Chats, persisted as one JSON file in Application Support.
@Observable
@MainActor
final class ChatStore {
    var chats: [Chat] = []
    /// A set so the sidebar supports ⇧/⌘ multi-select.
    var selection: Set<Chat.ID> = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BaseChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chats.json")
    }()

    init() {
        load()
        if chats.isEmpty { newChat() }
        selection = chats.first.map { [$0.id] } ?? []
    }

    /// The open chat — only when exactly one row is selected.
    var current: Chat? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return chats.first { $0.id == id }
    }

    var currentID: Chat.ID? { selection.count == 1 ? selection.first : nil }

    func newChat() {
        let chat = Chat()
        chats.insert(chat, at: 0)
        selection = [chat.id]
        save()
    }

    func delete(_ ids: Set<Chat.ID>) {
        guard !ids.isEmpty else { return }
        let index = chats.firstIndex { ids.contains($0.id) } ?? 0
        chats.removeAll { ids.contains($0.id) }
        if chats.isEmpty {
            newChat()
        } else {
            selection = [chats[min(index, chats.count - 1)].id]
        }
        save()
    }

    func append(_ message: Message, to id: Chat.ID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].messages.append(message)
        chats[i].updated = Date()
        if chats[i].messages.count == 1, message.role == .user {
            chats[i].title = Self.title(from: message.text)
        }
        save()
    }

    /// Streaming append — mutates the last assistant message in place.
    func updateLastAssistant(in id: Chat.ID, text: String) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].messages.lastIndex(where: { $0.role == .assistant })
        else { return }
        chats[i].messages[j].text = text
        chats[i].updated = Date()
    }

    private static func title(from text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 42 ? String(trimmed.prefix(42)) + "…" : (trimmed.isEmpty ? "New Chat" : trimmed)
    }

    // MARK: Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Chat].self, from: data)
        else { return }
        chats = decoded
    }
}
