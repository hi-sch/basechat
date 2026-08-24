import AppKit
import Foundation

/// Hands one answer to Apple Pages as a styled RTF document.
///
/// Markdown goes through the app's own parser rather than
/// `NSAttributedString(markdown:)`, which only records presentation *intents* —
/// they survive to RTF as flat, unstyled text. Building the attributed string
/// here means headings, lists, quotes and code arrive in Pages already styled.
@MainActor
enum PagesHandoff {

    static func open(_ message: Message, title: String) {
        let document = attributed(message, title: title)
        let range = NSRange(location: 0, length: document.length)
        guard let rtf = document.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else {
            NSSound.beep()
            return
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaseChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(for: title))

        do {
            try rtf.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let pages = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") {
            NSWorkspace.shared.open([url], withApplicationAt: pages, configuration: configuration)
        } else {
            // No Pages installed — hand it to whatever owns RTF.
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Markdown → attributed string

    private static let body: CGFloat = 12
    private static let headingSizes: [CGFloat] = [22, 18, 15, 13, 12, 12]

    private static func attributed(_ message: Message, title: String) -> NSAttributedString {
        let document = NSMutableAttributedString()

        for block in MarkdownParser.parse(message.text) {
            switch block {
            case .heading(let level, let text):
                let size = headingSizes[min(max(level, 1), 6) - 1]
                document.append(paragraph(inline(text, size: size, weight: .bold), spacingBefore: 10))

            case .paragraph(let text):
                document.append(paragraph(inline(text, size: body), spacingBefore: 4))

            case .list(let entries):
                for entry in entries {
                    let bullet: String
                    switch entry.marker {
                    case .bullet: bullet = "•\t"
                    case .number(let value): bullet = "\(value).\t"
                    case .task(let done): bullet = done ? "☑\t" : "☐\t"
                    }
                    let line = NSMutableAttributedString(string: bullet, attributes: [
                        .font: NSFont.systemFont(ofSize: body),
                    ])
                    line.append(inline(entry.text, size: body))
                    document.append(paragraph(line, spacingBefore: 2,
                                              indent: CGFloat(entry.indent + 1) * 18))
                }

            case .quote(let lines):
                let quote = inline(lines.joined(separator: "\n"), size: body, italic: true)
                document.append(paragraph(quote, spacingBefore: 6, indent: 22))

            case .code(_, let code):
                let mono = NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: body - 1, weight: .regular),
                ])
                document.append(paragraph(mono, spacingBefore: 6, indent: 18))

            case .table(let header, let rows):
                // RTF tables are not worth the ceremony — tab-separated keeps the
                // columns aligned and stays editable in Pages.
                for row in [header] + rows {
                    let line = NSAttributedString(string: row.joined(separator: "\t"), attributes: [
                        .font: NSFont.systemFont(ofSize: body),
                    ])
                    document.append(paragraph(line, spacingBefore: 2))
                }

            case .rule:
                document.append(paragraph(NSAttributedString(string: "———"), spacingBefore: 8))
            }
        }

        if document.length == 0 {
            document.append(paragraph(NSAttributedString(string: message.text), spacingBefore: 0))
        }
        return document
    }

    /// Inline markdown (emphasis, code spans, links) as real font traits.
    private static func inline(_ source: String, size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let result = NSMutableAttributedString(parsed)
        let whole = NSRange(location: 0, length: result.length)

        var base = NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            base = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
        result.addAttribute(.font, value: base, range: whole)

        // Re-apply the traits the markdown parser recorded as intents.
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var font = base
            if intent.contains(.stronglyEmphasized) {
                font = NSFont.systemFont(ofSize: size, weight: .bold)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
            }
            result.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }

    private static func paragraph(_ content: NSAttributedString, spacingBefore: CGFloat, indent: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = 2
        style.lineHeightMultiple = 1.15
        style.firstLineHeadIndent = indent
        style.headIndent = indent

        let line = NSMutableAttributedString(attributedString: content)
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func filename(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = title.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Answer" : name) + ".rtf"
    }
}
