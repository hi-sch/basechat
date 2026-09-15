import Foundation
import Observation

/// Chats, persisted as one JSON file in Application Support.
@Observable
@MainActor
final class ChatStore {
    var chats: [Chat] = []
    /// A set so the sidebar supports ⇧/⌘ multi-select.
    var selection: Set<Chat.ID> = []
    /// Shown in the composer when a write to `chats.json` fails.
    var persistError: String?

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

    func delete(_ ids: Set<Chat.ID>, undoManager: UndoManager? = nil) {
        guard !ids.isEmpty else { return }
        let index = chats.firstIndex { ids.contains($0.id) } ?? 0
        let removed = chats.filter { ids.contains($0.id) }
        let previousSelection = selection
        chats.removeAll { ids.contains($0.id) }
        if chats.isEmpty {
            newChat()
        } else {
            selection = [chats[min(index, chats.count - 1)].id]
        }
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(removed, at: index, selection: previousSelection, undoManager: undoManager)
        }
        undoManager?.setActionName(removed.count == 1 ? "Delete Chat" : "Delete Chats")
    }

    private func restore(_ items: [Chat], at index: Int, selection: Set<Chat.ID>, undoManager: UndoManager?) {
        let insert = min(index, chats.count)
        chats.insert(contentsOf: items, at: insert)
        self.selection = selection
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.delete(Set(items.map(\.id)), undoManager: undoManager)
        }
        undoManager?.setActionName(items.count == 1 ? "Delete Chat" : "Delete Chats")
    }

    func rename(_ id: Chat.ID, to title: String, undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? "New Chat" : trimmed
        let previous = chats[i].title
        guard next != previous else { return }
        chats[i].title = next
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.rename(id, to: previous, undoManager: undoManager)
        }
        undoManager?.setActionName("Rename Chat")
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
    func updateLastAssistant(
        in id: Chat.ID,
        text: String? = nil,
        reasoning: String? = nil,
        tokensPerSecond: Double? = nil,
        contextTrimmed: Bool? = nil
    ) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].messages.lastIndex(where: { $0.role == .assistant })
        else { return }
        if let text { chats[i].messages[j].text = text }
        if let reasoning {
            let current = chats[i].messages[j].reasoning ?? ""
            chats[i].messages[j].reasoning = current + reasoning
        }
        if let tokensPerSecond { chats[i].messages[j].tokensPerSecond = tokensPerSecond }
        if let contextTrimmed { chats[i].messages[j].contextTrimmed = contextTrimmed }
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

    func add(_ annotation: Annotation, to id: Chat.ID, undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].annotations.append(annotation)
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.removeAnnotation(annotation.id, in: id, undoManager: undoManager)
        }
        undoManager?.setActionName("Add Markup")
    }

    func update(_ annotation: Annotation, in id: Chat.ID, undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].annotations.firstIndex(where: { $0.id == annotation.id })
        else { return }
        let before = chats[i].annotations[j]
        chats[i].annotations[j] = annotation
        save()
        // A note being typed updates on every keystroke; that belongs to the
        // field's own undo, not the document's.
        guard let undoManager, before.text == annotation.text, before != annotation else { return }
        undoManager.registerUndo(withTarget: self) { store in
            store.update(before, in: id, undoManager: undoManager)
        }
        undoManager.setActionName("Change Markup")
    }

    /// Moves a mark to the front or the back of the stack it is drawn in.
    func reorder(_ annotationID: Annotation.ID, toFront: Bool, in id: Chat.ID,
                 undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].annotations.firstIndex(where: { $0.id == annotationID }),
              chats[i].annotations.count > 1
        else { return }
        let mark = chats[i].annotations.remove(at: j)
        chats[i].annotations.insert(mark, at: toFront ? chats[i].annotations.endIndex : 0)
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(mark, at: j, in: id, undoManager: undoManager)
        }
        undoManager?.setActionName(toFront ? "Bring Markup to Front" : "Send Markup to Back")
    }

    private func restore(_ annotation: Annotation, at index: Int, in id: Chat.ID,
                         undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let j = chats[i].annotations.firstIndex(where: { $0.id == annotation.id })
        else { return }
        let mark = chats[i].annotations.remove(at: j)
        chats[i].annotations.insert(mark, at: min(index, chats[i].annotations.endIndex))
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.restore(mark, at: j, in: id, undoManager: undoManager)
        }
    }

    func removeAnnotation(_ annotationID: Annotation.ID, in id: Chat.ID, undoManager: UndoManager? = nil) {
        guard let i = chats.firstIndex(where: { $0.id == id }),
              let annotation = chats[i].annotations.first(where: { $0.id == annotationID })
        else { return }
        chats[i].annotations.removeAll { $0.id == annotationID }
        save()
        undoManager?.registerUndo(withTarget: self) { store in
            store.add(annotation, to: id, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Markup")
    }

    private static func title(from text: String) -> String {
        var line = text.split(separator: "\n").first.map(String.init) ?? text
        line = line.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        for mark in ["**", "__", "*", "_", "`"] {
            if line.hasPrefix(mark), line.hasSuffix(mark), line.count > mark.count * 2 {
                line = String(line.dropFirst(mark.count).dropLast(mark.count))
            }
        }
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
        do {
            let data = try JSONEncoder().encode(chats)
            try data.write(to: url, options: .atomic)
            persistError = nil
        } catch {
            persistError = "Could not save chats: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Chat].self, from: data)
        else { return }
        chats = decoded
    }
}
