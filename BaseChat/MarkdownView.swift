import AppKit
import SwiftUI

// MARK: - Blocks

struct ListEntry {
    enum Marker {
        case bullet
        case number(Int)
        case task(done: Bool)
    }
    var indent: Int
    var marker: Marker
    var text: String
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListEntry])
    case quote([String])
    case code(language: String, code: String)
    case table(header: [String], rows: [[String]])
    case rule
}

// MARK: - Parser

enum MarkdownParser {

    /// Parsing runs inside `body`, so it happens again on every layout pass —
    /// once for the measuring pass and once for the sheet, for every turn in the
    /// conversation. Cache it: the text of a turn almost never changes, and the
    /// one that does is the tail being streamed.
    @MainActor private static var cache: [String: [MarkdownBlock]] = [:]
    @MainActor private static var order: [String] = []
    private static let cacheLimit = 400

    @MainActor
    static func parse(_ source: String) -> [MarkdownBlock] {
        if let hit = cache[source] { return hit }
        let blocks = compute(source)
        cache[source] = blocks
        order.append(source)
        if order.count > cacheLimit {
            let stale = order.removeFirst()
            cache.removeValue(forKey: stale)
        }
        return blocks
    }

    private static func compute(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [ListEntry] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !list.isEmpty else { return }
            blocks.append(.list(list))
            list = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote))
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        let lines = normalize(source).components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // One-line fence: ```python print("hi") ```
            if let fenced = oneLineFence(trimmed) {
                flushAll()
                blocks.append(.code(language: fenced.language, code: fenced.code))
                index += 1
                continue
            }

            // Fenced code — an unterminated fence still renders while streaming.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language, code: body.joined(separator: "\n")))
                continue
            }

            if trimmed.lowercased().hasPrefix("<pre") {
                flushAll()
                var body: [String] = []
                var current = trimmed
                while true {
                    body.append(current)
                    if current.lowercased().contains("</pre>") { break }
                    index += 1
                    guard index < lines.count else { break }
                    current = lines[index]
                }
                index += 1
                blocks.append(.code(language: "", code: htmlCodeBody(body.joined(separator: "\n"))))
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // Table: a pipe row followed by a |---|---| separator.
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushAll()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Setext heading: underlined by === or ---.
            if !paragraph.isEmpty, trimmed.range(of: "^(=+|-+)$", options: .regularExpression) != nil {
                let text = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                index += 1
                continue
            }

            if trimmed.range(of: "^([-*_])\\1{2,}$", options: .regularExpression) != nil {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            // ATX heading.
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                    index += 1
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            if let entry = listEntry(line) {
                flushParagraph()
                flushQuote()
                list.append(entry)
                index += 1
                continue
            }

            // A plain indented line right after a list item continues that item.
            if !list.isEmpty, line.hasPrefix("  ") {
                list[list.count - 1].text += " " + trimmed
                index += 1
                continue
            }

            // Indented code (4 spaces / tab). CommonMark only starts this after
            // a blank line, which already flushed the paragraph.
            if paragraph.isEmpty, list.isEmpty, indentWidth(line) >= 4 {
                flushQuote()
                var body: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, indentWidth(lines[index + 1]) >= 4 {
                            body.append("")
                            index += 1
                            continue
                        }
                        break
                    }
                    guard indentWidth(current) >= 4 else { break }
                    body.append(dropIndent(current, 4))
                    index += 1
                }
                if !body.isEmpty {
                    blocks.append(.code(language: "", code: body.joined(separator: "\n")))
                    continue
                }
            }

            flushList()
            flushQuote()
            paragraph.append(trimmed)
            index += 1
        }
        flushAll()
        return blocks
    }

    private static func listEntry(_ line: String) -> ListEntry? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = min(leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2, 4)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Task list first — it is a bullet with a checkbox.
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            let rest = String(trimmed.dropFirst(2))
            let lower = rest.lowercased()
            if lower.hasPrefix("[ ] ") || lower.hasPrefix("[x] ") {
                return ListEntry(indent: indent,
                                 marker: .task(done: lower.hasPrefix("[x] ")),
                                 text: String(rest.dropFirst(4)))
            }
            return ListEntry(indent: indent, marker: .bullet, text: rest)
        }

        if let dot = trimmed.firstIndex(of: "."),
           trimmed.distance(from: trimmed.startIndex, to: dot) <= 2,
           let number = Int(trimmed[trimmed.startIndex..<dot]),
           trimmed[dot...].hasPrefix(". ") {
            return ListEntry(indent: indent,
                             marker: .number(number),
                             text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
        }
        if let paren = trimmed.firstIndex(of: ")"),
           trimmed.distance(from: trimmed.startIndex, to: paren) <= 2,
           let number = Int(trimmed[trimmed.startIndex..<paren]),
           trimmed[paren...].hasPrefix(") ") {
            return ListEntry(indent: indent,
                             marker: .number(number),
                             text: String(trimmed[trimmed.index(paren, offsetBy: 2)...]))
        }
        return nil
    }

    /// Models sometimes emit a fence on one line instead of wrapping the body.
    private static func oneLineFence(_ trimmed: String) -> (language: String, code: String)? {
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let mark = trimmed.first!
        var ticks = 0
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex, trimmed[cursor] == mark {
            ticks += 1
            cursor = trimmed.index(after: cursor)
        }
        guard ticks >= 3 else { return nil }
        let close = String(repeating: String(mark), count: ticks)
        let rest = String(trimmed[cursor...])
        guard let closeRange = rest.range(of: close, options: .backwards),
              closeRange.lowerBound > rest.startIndex else { return nil }
        let inner = rest[..<closeRange.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        if let space = inner.firstIndex(of: " ") {
            let language = String(inner[..<space])
            let code = inner[inner.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if language.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "_" }),
               !code.isEmpty {
                return (language, code)
            }
        }
        return ("", inner)
    }

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    private static func dropIndent(_ line: String, _ width: Int) -> String {
        var remaining = width
        var index = line.startIndex
        while index < line.endIndex, remaining > 0 {
            if line[index] == " " {
                remaining -= 1
                index = line.index(after: index)
            } else if line[index] == "\t" {
                remaining -= 4
                index = line.index(after: index)
            } else {
                break
            }
        }
        return String(line[index...])
    }

    private static func htmlCodeBody(_ raw: String) -> String {
        var text = raw
        if let open = text.range(of: ">", options: []) {
            text = String(text[open.upperBound...])
        }
        if let close = text.range(of: "</pre>", options: [.caseInsensitive, .backwards]) {
            text = String(text[..<close.lowerBound])
        }
        text = text.replacingOccurrences(of: "</code>", with: "", options: .caseInsensitive)
        if let open = text.range(of: "<code", options: .caseInsensitive),
           let end = text[open.lowerBound...].range(of: ">") {
            text = String(text[end.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Expand the line-break spellings small MLX models often emit instead of
    /// real newlines, so fences and lists actually parse.
    private static func normalize(_ source: String) -> String {
        var text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        if !text.contains(where: { $0 == "\n" }), text.contains("\\n") {
            text = text.replacingOccurrences(of: "\\n", with: "\n")
        }
        return text
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.range(of: "^\\|?[\\s:-]+\\|[\\s:|-]*$", options: .regularExpression) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline markdown — emphasis, code spans, links. `highlight` washes every
    /// occurrence of a search term in Notes yellow.
    ///
    /// The markdown pass is cached alongside the block parse: it runs inside
    /// `body`, once per paragraph, on every redraw of every visible turn.
    @MainActor
    static func inline(_ source: String, highlight: String = "") -> Text {
        let attributed = spans[source] ?? {
            let options = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let parsed = (try? AttributedString(markdown: source, options: options))
                ?? AttributedString(source)
            let selectable = Self.crossLineSelection(parsed)
            remember(source, selectable)
            return selectable
        }()
        guard !highlight.isEmpty else { return Text(attributed) }
        return Text(SearchIndex.emphasise(attributed, term: highlight))
    }

    /// SwiftUI `Text` selection cannot cross a paragraph break (`\n`). Line
    /// Separator (U+2028) still wraps visually but stays one paragraph, so a
    /// drag can run through a whole message that contains returns.
    static func crossLineSelection(_ attributed: AttributedString) -> AttributedString {
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        for needle in ["\r\n", "\n", "\r"] {
            let range = NSRange(location: 0, length: ns.length)
            ns.mutableString.replaceOccurrences(
                of: needle, with: "\u{2028}", options: [], range: range)
        }
        return AttributedString(ns)
    }

    static func crossLineSelection(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: "\u{2028}")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
            .replacingOccurrences(of: "\r", with: "\u{2028}")
    }

    @MainActor private static var spans: [String: AttributedString] = [:]
    @MainActor private static var spanOrder: [String] = []

    @MainActor
    private static func remember(_ source: String, _ parsed: AttributedString) {
        spans[source] = parsed
        spanOrder.append(source)
        if spanOrder.count > cacheLimit {
            spans.removeValue(forKey: spanOrder.removeFirst())
        }
    }
}

// MARK: - Rendering

struct MarkdownView: View {
    let text: String
    var highlight: String = ""
    /// Body type size. Every other size in the renderer is a multiple of it, so
    /// the whole block shrinks together — the document uses `Paper.bodySize`,
    /// the continuous transcript stays at the system size.
    var baseSize: CGFloat = 13
    /// On paper nothing scrolls: code and tables wrap instead, and the PDF
    /// renderer draws them — a scroll view comes out of ImageRenderer empty.
    var document = false

    private var ratio: CGFloat { baseSize / 13 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * ratio) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .flow(let text):
                    text.fixedSize(horizontal: false, vertical: true)
                case .block(let block):
                    view(for: block)
                }
            }
        }
        .font(.system(size: baseSize))
        .textSelection(.enabled)
        // SwiftUI only swaps in the I-beam directly over glyphs, if at all —
        // message text should feel like text everywhere, code and tables too.
        .onHover { inside in
            if inside { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
        }
    }

    /// Headings and paragraphs concatenate into one `Text`, so a selection can
    /// run across blank lines instead of dying at each paragraph view.
    private enum Piece {
        case flow(Text)
        case block(MarkdownBlock)
    }

    private var pieces: [Piece] {
        var result: [Piece] = []
        var flow: Text?
        let breakBetween = Text(MarkdownParser.crossLineSelection("\n\n"))
        func flush() {
            if let flow { result.append(.flow(flow)) }
            flow = nil
        }
        for block in MarkdownParser.parse(text) {
            if let run = flowText(for: block) {
                flow = flow.map { $0 + breakBetween + run } ?? run
            } else {
                flush()
                result.append(.block(block))
            }
        }
        flush()
        return result
    }

    private func flowText(for block: MarkdownBlock) -> Text? {
        switch block {
        case .heading(let level, let text):
            return MarkdownParser.inline(text, highlight: highlight)
                .font(.system(size: Self.headingSizes[min(max(level, 1), 6) - 1] * ratio, weight: .semibold))
        case .paragraph(let text):
            return MarkdownParser.inline(text, highlight: highlight)
        case .list(let entries):
            var run: Text?
            let breakLine = Text("\u{2028}")
            for entry in entries {
                let mark: Text = {
                    switch entry.marker {
                    case .bullet: return Text(entry.indent == 0 ? "•  " : "◦  ")
                    case .number(let value): return Text("\(value).  ")
                    case .task(let done): return Text(done ? "☑  " : "☐  ")
                    }
                }()
                let indent = String(repeating: "    ", count: entry.indent)
                let line = Text(indent) + mark + MarkdownParser.inline(entry.text, highlight: highlight)
                run = run.map { $0 + breakLine + line } ?? line
            }
            return run
        case .quote(let lines):
            return MarkdownParser.inline(lines.joined(separator: "\n"), highlight: highlight)
                .foregroundStyle(.secondary)
        case .code, .table, .rule:
            return nil
        }
    }

    private static let headingSizes: [CGFloat] = [22, 19, 17, 15, 14, 13]

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading, .paragraph, .list, .quote:
            EmptyView()
        case .code(let language, let code):
            CodeBlock(language: language, code: code, baseSize: baseSize, document: document)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, baseSize: baseSize, document: document)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func marker(for entry: ListEntry) -> some View {
        switch entry.marker {
        case .bullet:
            Text(entry.indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
        case .number(let value):
            Text("\(value).").foregroundStyle(.secondary).monospacedDigit()
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: baseSize))
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    var baseSize: CGFloat = 13
    var document = false

    private var ratio: CGFloat { baseSize / 13 }

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Scrollable(document: document) {
            Grid(alignment: .leading, horizontalSpacing: 16 * ratio, verticalSpacing: 7 * ratio) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        MarkdownParser.inline(column < header.count ? header[column] : "")
                            .font(.system(size: baseSize - 1, weight: .semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            MarkdownParser.inline(column < row.count ? row[column] : "")
                                .font(.system(size: baseSize - 1))
                        }
                    }
                }
            }
            .padding(12 * ratio)
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12 * ratio))
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    var baseSize: CGFloat = 13
    var document = false
    @State private var copied = false

    private var ratio: CGFloat { baseSize / 13 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: baseSize - 3))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: baseSize - 2))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12 * ratio)
            .padding(.vertical, 6 * ratio)

            Divider().opacity(0.4)

            Scrollable(document: document) {
                Text(MarkdownParser.crossLineSelection(code))
                    .font(.system(size: baseSize - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12 * ratio)
            }
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12 * ratio))
    }
}


/// Scrolls sideways on screen, wraps on paper. `ImageRenderer` draws a scroll
/// view as blank space, which is why code blocks were missing from the PDF.
struct Scrollable<Content: View>: View {
    let document: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if document {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}
