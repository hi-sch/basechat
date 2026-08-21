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

    static func parse(_ source: String) -> [MarkdownBlock] {
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

        let lines = source.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
        return nil
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

    /// Inline markdown — emphasis, code spans, links.
    static func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: source, options: options) {
            return Text(attributed)
        }
        return Text(source)
    }
}

// MARK: - Rendering

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    private static let headingSizes: [CGFloat] = [22, 19, 17, 15, 14, 13]

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownParser.inline(text)
                .font(.system(size: Self.headingSizes[min(max(level, 1), 6) - 1], weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            MarkdownParser.inline(text)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let entries):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(for: entry)
                        MarkdownParser.inline(entry.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(entry.indent) * 18)
                }
            }

        case .quote(let lines):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(.tint.opacity(0.5)).frame(width: 3)
                MarkdownParser.inline(lines.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let code):
            CodeBlock(language: language, code: code)

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)

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
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        MarkdownParser.inline(column < header.count ? header[column] : "")
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            MarkdownParser.inline(column < row.count ? row[column] : "")
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2)
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
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }
}
