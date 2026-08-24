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

    /// Drops every turn after `messageID` — the first half of "regenerate from here".
    /// Returns the history the model should see, i.e. everything up to and including it.
    @discardableResult
    func truncate(_ id: Chat.ID, after messageID: Message.ID) -> [Message] {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].messages.firstIndex(where: { $0.id == messageID })
        else { return [] }
        chats[i].messages.removeSubrange((j + 1)...)
        chats[i].updated = Date()
        save()
        return chats[i].messages
    }

    // MARK: Annotations

    func annotations(in id: Chat.ID?) -> [Annotation] {
        guard let id, let chat = chats.first(where: { $0.id == id }) else { return [] }
        return chat.annotations
    }

    func add(_ annotation: Annotation, to id: Chat.ID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].annotations.append(annotation)
        save()
    }

    func update(_ annotation: Annotation, in id: Chat.ID) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].annotations.firstIndex(where: { $0.id == annotation.id })
        else { return }
        chats[i].annotations[j] = annotation
        save()
    }

    func removeAnnotation(_ annotationID: Annotation.ID, in id: Chat.ID) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].annotations.removeAll { $0.id == annotationID }
        save()
    }

    private static func title(from text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 42 ? String(trimmed.prefix(42)) + "…" : (trimmed.isEmpty ? "New Chat" : trimmed)
    }

    // MARK: Persistence

    private var pendingWrite: Task<Void, Never>?

    /// Coalesced: a save encodes every chat, and the callers are appends and
    /// markup edits that arrive in bursts. Anything that must not be lost calls
    /// `flush` instead.
    func save() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    /// Writes now and cancels any pending save — for app termination.
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func write() {
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
