import SwiftUI

// MARK: - State

@Observable
@MainActor
final class SearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case everywhere, thisChat
        var id: String { rawValue }
        var label: String { self == .everywhere ? "All Chats" : "This Chat" }
    }

    var query = ""
    var scope: Scope = .everywhere
    /// The field only takes up a toolbar slot once it has been asked for —
    /// ⌘F or the overflow menu. Otherwise that slot holds copy and the ellipsis.
    var visible = false
    /// Bumped every time the field is asked for, so ⌘F takes the caret back
    /// even when the field is already up.
    private(set) var focusRequests = 0

    func open() {
        visible = true
        focusRequests += 1
    }

    var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { visible && !term.isEmpty }

    /// Back to the plain sidebar: puts the term, the scope and the field away.
    func exit() {
        query = ""
        scope = .everywhere
        visible = false
    }
}

// MARK: - Matching

struct SearchHit: Identifiable {
    let id: Message.ID
    let role: Message.Role
    let snippet: AttributedString
}

@MainActor
enum SearchIndex {

    // Scanning is per chat, but the sidebar asks for it on every redraw — and
    // during a reply that is once per token, for every conversation on file.
    // Results are kept per chat until either the term or that chat changes.
    private static var term = ""
    private static var counts: [Chat.ID: (stamp: Date, value: Int)] = [:]
    private static var snippets: [Chat.ID: (stamp: Date, value: [SearchHit])] = [:]

    private static func invalidate(unless current: String) {
        guard term != current else { return }
        term = current
        counts.removeAll(keepingCapacity: true)
        snippets.removeAll(keepingCapacity: true)
    }

    static func matchCount(_ chat: Chat, term: String) -> Int {
        guard !term.isEmpty else { return 0 }
        invalidate(unless: term)
        if let cached = counts[chat.id], cached.stamp == chat.lastActivity { return cached.value }
        var total = chat.title.range(of: term, options: .caseInsensitive) != nil ? 1 : 0
        for message in chat.messages {
            total += ranges(in: message.text, term: term).count
        }
        counts[chat.id] = (chat.lastActivity, total)
        return total
    }

    static func hits(_ chat: Chat, term: String, limit: Int = 4) -> [SearchHit] {
        guard !term.isEmpty else { return [] }
        invalidate(unless: term)
        if let cached = snippets[chat.id], cached.stamp == chat.lastActivity { return cached.value }
        var found: [SearchHit] = []
        for message in chat.messages {
            guard let first = ranges(in: message.text, term: term).first else { continue }
            found.append(SearchHit(id: message.id, role: message.role,
                                   snippet: snippet(message.text, around: first, term: term)))
            if found.count == limit { break }
        }
        snippets[chat.id] = (chat.lastActivity, found)
        return found
    }

    /// Every case-insensitive occurrence of `term`.
    static func ranges(in text: String, term: String) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: term, options: .caseInsensitive, range: cursor..<text.endIndex) {
            found.append(range)
            cursor = range.upperBound
        }
        return found
    }

    /// Notes-style one-liner: a window of text around the match, match emphasised.
    static func snippet(_ text: String, around range: Range<String.Index>, term: String) -> AttributedString {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lead = 28
        guard let match = flat.range(of: term, options: .caseInsensitive) else {
            return AttributedString(String(flat.prefix(90)))
        }
        let start = flat.index(match.lowerBound, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(match.upperBound, offsetBy: 70, limitedBy: flat.endIndex) ?? flat.endIndex
        var window = String(flat[start..<end])
        if start > flat.startIndex { window = "…" + window }
        if end < flat.endIndex { window += "…" }
        return emphasise(AttributedString(window), term: term)
    }

    /// Paints every occurrence of `term` with the Notes-style yellow wash.
    static func emphasise(_ source: AttributedString, term: String) -> AttributedString {
        guard !term.isEmpty else { return source }
        var result = source
        var cursor = result.startIndex
        while cursor < result.endIndex,
              let range = result[cursor...].range(of: term, options: .caseInsensitive) {
            result[range].backgroundColor = Color.yellow.opacity(0.55)
            result[range].foregroundColor = .black
            cursor = range.upperBound
        }
        return result
    }
}

// MARK: - Toolbar field

/// The pill in `design_insp_5` — magnifier, a scope chevron, and the field.
struct SearchField: View {
    @Bindable var search: SearchModel

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Scope", selection: $search.scope) {
                    ForEach(SearchModel.Scope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.inline)

                Divider()
                Button("Close Search") { search.exit() }
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            SearchTextField(text: $search.query,
                            focusRequests: search.focusRequests,
                            onCancel: { search.exit() })
                .frame(width: 150, height: 18)

            Button {
                search.exit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close search")
        }
        .padding(.horizontal, 4)
    }
}

/// An `NSTextField` rather than a SwiftUI one.
///
/// A toolbar item is hosted in its own view tree, outside the focus system the
/// main view uses, so `@FocusState` there never takes — which is why ⌘F opened
/// the field without putting the caret in it. Owning the control means the
/// responder can simply be set.
struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    var focusRequests: Int
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 12)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.isAutomaticTextCompletionEnabled = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCancel = onCancel
        if field.stringValue != text {
            field.stringValue = text
        }
        guard context.coordinator.servedRequest != focusRequests else { return }
        context.coordinator.servedRequest = focusRequests
        context.coordinator.claimFocus(of: field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onCancel: onCancel) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var onCancel: () -> Void
        /// Which focus request has already been honoured.
        var servedRequest = -1

        init(text: Binding<String>, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCancel = onCancel
        }

        /// The field is created before it joins a window, so keep asking for a
        /// few runloop turns rather than giving up on the first miss.
        func claimFocus(of field: NSTextField, attempt: Int = 0) {
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                if let window = field.window {
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectedRange =
                        NSRange(location: field.stringValue.count, length: 0)
                } else if attempt < 10 {
                    self.claimFocus(of: field, attempt: attempt + 1)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Sidebar row

struct ChatRow: View {
    let chat: Chat
    let term: String

    private var hits: [SearchHit] { term.isEmpty ? [] : SearchIndex.hits(chat, term: term) }

    private static func matchLabel(_ count: Int) -> String {
        count == 1 ? "1 match" : "\(count) matches"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term.isEmpty ? AttributedString(chat.title)
                              : SearchIndex.emphasise(AttributedString(chat.title), term: term))
                .font(.headline)
                .lineLimit(1)

            if term.isEmpty {
                HStack(spacing: 6) {
                    Text(chat.dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(chat.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 6) {
                    Text(chat.dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.matchLabel(SearchIndex.matchCount(chat, term: term)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: hit.role == .user ? "person.fill" : "sparkle")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 3)
                        Text(hit.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
