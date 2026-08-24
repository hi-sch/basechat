import AppKit
import SwiftUI

// MARK: - Styles the format menu can apply

enum TextStyle: Hashable, CaseIterable {
    case title, heading, subheading, body
    case bold, italic, strikethrough, monospaced
    case bulleted, numbered, quote, codeBlock

    var label: String {
        switch self {
        case .title: return "Title"
        case .heading: return "Heading"
        case .subheading: return "Subheading"
        case .body: return "Body"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .monospaced: return "Monospaced"
        case .bulleted: return "Bulleted List"
        case .numbered: return "Numbered List"
        case .quote: return "Block Quote"
        case .codeBlock: return "Code Block"
        }
    }

    var symbol: String {
        switch self {
        case .title: return "textformat.size.larger"
        case .heading: return "textformat.size"
        case .subheading: return "textformat.size.smaller"
        case .body: return "textformat"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .monospaced: return "chevron.left.forwardslash.chevron.right"
        case .bulleted: return "list.bullet"
        case .numbered: return "list.number"
        case .quote: return "text.quote"
        case .codeBlock: return "curlybraces"
        }
    }

    var shortcut: KeyEquivalent? {
        switch self {
        case .bold: return "b"
        case .italic: return "i"
        default: return nil
        }
    }

    /// Inline styles wrap the selection; the rest rewrite whole lines.
    var inlineMarker: String? {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .monospaced: return "`"
        default: return nil
        }
    }

    var linePrefix: String? {
        switch self {
        case .title: return "# "
        case .heading: return "## "
        case .subheading: return "### "
        case .body: return ""
        case .bulleted: return "- "
        case .numbered: return "1. "
        case .quote: return "> "
        default: return nil
        }
    }
}

// MARK: - Applies styles to the live NSTextView selection

@MainActor
final class ComposerController {
    weak var textView: NSTextView?

    private static let prefixPattern = try! NSRegularExpression(
        pattern: "^(\\s*)(#{1,6} |> |[-*+] |\\d+\\. )?"
    )

    func focus() { textView?.window?.makeFirstResponder(textView) }

    func apply(_ style: TextStyle) {
        guard let textView else { return }
        if let marker = style.inlineMarker {
            wrap(textView, with: marker)
        } else if let prefix = style.linePrefix {
            prefixLines(textView, with: prefix)
        } else if style == .codeBlock {
            fence(textView)
        }
        textView.window?.makeFirstResponder(textView)
    }

    private func replace(_ textView: NSTextView, range: NSRange, with string: String, select: NSRange) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.setSelectedRange(select)
    }

    private func wrap(_ textView: NSTextView, with marker: String) {
        let text = textView.string as NSString
        let range = textView.selectedRange()
        let selected = text.substring(with: range)
        let width = marker.count

        // Already wrapped? Toggle it off.
        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.count >= width * 2 {
            let stripped = String(selected.dropFirst(width).dropLast(width))
            replace(textView, range: range, with: stripped,
                    select: NSRange(location: range.location, length: (stripped as NSString).length))
            return
        }
        let outer = NSRange(location: max(0, range.location - width),
                            length: min(range.length + width * 2, text.length - max(0, range.location - width)))
        if outer.length >= width * 2 {
            let padded = text.substring(with: outer)
            if padded.hasPrefix(marker), padded.hasSuffix(marker) {
                replace(textView, range: outer, with: selected,
                        select: NSRange(location: outer.location, length: (selected as NSString).length))
                return
            }
        }

        let wrapped = marker + selected + marker
        // Empty selection: drop the caret between the markers so typing lands inside.
        let caret = range.length == 0
            ? NSRange(location: range.location + width, length: 0)
            : NSRange(location: range.location, length: (wrapped as NSString).length)
        replace(textView, range: range, with: wrapped, select: caret)
    }

    private func prefixLines(_ textView: NSTextView, with prefix: String) {
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: textView.selectedRange())
        let block = text.substring(with: lineRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = lines.count > 1 && lines.last == ""
        if trailingNewline { lines.removeLast() }

        func stripped(_ line: String) -> (indent: String, body: String) {
            let ns = line as NSString
            guard let match = Self.prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            else { return ("", line) }
            let indent = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
            return (indent, ns.substring(from: match.range.upperBound))
        }

        // Toggle off when every line already carries this exact prefix.
        let bodies = lines.map { stripped($0) }
        let alreadyApplied = !prefix.isEmpty && lines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return prefix == "1. "
                ? (trimmed.range(of: "^\\d+\\. ", options: .regularExpression) != nil)
                : trimmed.hasPrefix(prefix.trimmingCharacters(in: .whitespaces) + " ")
        }

        var rewritten: [String] = []
        for (index, part) in bodies.enumerated() {
            if prefix.isEmpty || alreadyApplied {
                rewritten.append(part.indent + part.body)
            } else if prefix == "1. " {
                rewritten.append("\(part.indent)\(index + 1). \(part.body)")
            } else {
                rewritten.append(part.indent + prefix + part.body)
            }
        }

        var result = rewritten.joined(separator: "\n")
        if trailingNewline { result += "\n" }
        replace(textView, range: lineRange, with: result,
                select: NSRange(location: lineRange.location, length: (result as NSString).length))
    }

    private func fence(_ textView: NSTextView) {
        let text = textView.string as NSString
        let range = textView.selectedRange()
        let selected = text.substring(with: range)
        let needsLeadingBreak = range.location > 0 && !text.substring(to: range.location).hasSuffix("\n")
        let block = (needsLeadingBreak ? "\n" : "") + "```\n" + selected + "\n```\n"
        let caret = range.location + (needsLeadingBreak ? 1 : 0) + 4 + (selected as NSString).length
        replace(textView, range: range, with: block, select: NSRange(location: caret, length: 0))
    }
}

// MARK: - The text view itself

/// NSTextView with markdown-safe typing (no smart quotes/dashes) and ⌘↩ to send.
final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// Fired when the caret lands here, so the rest of the app can drop any
    /// selection that would otherwise swallow the next Delete.
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var controller: ComposerController
    var onSubmit: () -> Void
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onFocus = onFocus
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        // Default padding insets the caret ~5pt from the placeholder; zero it so they line up.
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.onSubmit = onSubmit
        textView.onFocus = onFocus
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.reportHeight(of: textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MarkdownEditor

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(of: textView)
        }

        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            let clamped = min(max(used, 21), 220)
            if abs(clamped - parent.height) > 0.5 {
                DispatchQueue.main.async { [parent] in parent.height = clamped }
            }
        }
    }
}
