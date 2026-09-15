import AppKit
import SwiftUI

/// Marking up text the reader has already selected.
///
/// The highlighter answers a selection the way Preview does: select first, then
/// reach for the pen, and the words you had selected come out marked. SwiftUI
/// will not say what its text views have selected, so this is put together from
/// the two things it will do — hand the selection to the clipboard, and lay the
/// turn out again the same way twice.
@MainActor
enum TextSelectionMarkup {

    /// What the transcript has selected right now, if anything.
    ///
    /// There is no read-only way to ask. Copy is the one door AppKit leaves
    /// open, so the clipboard is put back exactly as it was afterwards and the
    /// user never sees it move.
    static func selectedText() -> String? {
        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []

        defer {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }

        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil),
              board.changeCount != before,
              let text = board.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// The marks that cover `selection` — one per sheet it runs across, each
    /// carrying a band per line, exactly as a drag with the pen would.
    ///
    /// Empty when the selection cannot be placed with confidence: when no turn
    /// holds it, when several do, or when the same words appear twice in the
    /// turn that does. There is no way to tell which copy was selected, and a
    /// band over the wrong sentence is worse than none.
    static func marks(for selection: String, in chat: Chat,
                      layout: DocumentLayout, state: AnnotationState) -> [Annotation] {
        let fragments = selection
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 1 }
        // The longest line is the one to look for: it is the least likely to
        // appear twice, and the least likely to be all markdown punctuation.
        guard let needle = fragments.max(by: { $0.count < $1.count }).map(flatten) else { return [] }

        var found: Message?
        for message in chat.messages {
            let haystack = flatten(message.text)
            switch occurrences(of: needle, in: haystack) {
            case 0: continue
            case 1: if found != nil { return [] }; found = message
            default: return []
            }
        }
        guard let message = found else { return [] }

        let boxes = InkMap.runs(of: message, matching: selection)
        guard !boxes.isEmpty else { return [] }

        // A turn can flow across sheets, and a mark belongs to one sheet, so
        // each slice keeps the bands that landed on it.
        let pad = Paper.inkPad / Paper.height
        let top = Paper.margin / Paper.height
        let bottom = (Paper.height - Paper.margin - Paper.footer) / Paper.height

        var made: [Annotation] = []
        for (page, placements) in layout.pages(chat.messages).enumerated() {
            for placement in placements where placement.message.id == message.id {
                let bands = boxes.compactMap { box -> CGRect? in
                    let y = (Paper.margin + placement.y + box.minY) / Paper.height
                    let height = box.height / Paper.height
                    guard y >= top - pad, y + height <= bottom + pad else { return nil }
                    return CGRect(x: (Paper.margin + box.minX) / Paper.width,
                                  y: y - pad,
                                  width: box.width / Paper.width,
                                  height: height + pad * 2)
                }
                guard !bands.isEmpty else { continue }
                var mark = state.draft(kind: state.markKind, page: page)
                mark.bands = bands
                mark.rect = AnnotationLayer.union(bands)
                made.append(mark)
            }
        }
        return made
    }

    /// Markdown as the reader sees it — near enough to count occurrences in.
    /// Both sides of the comparison go through it, so a selection copied out of
    /// the rendered text still matches the source it came from.
    private static func flatten(_ text: String) -> String {
        var out = text
        for marker in ["**", "__", "~~", "`", "*", "_", "#", ">"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let range = haystack.range(of: needle, options: .caseInsensitive,
                                         range: cursor..<haystack.endIndex) {
            count += 1
            if count > 1 { return count }
            cursor = range.upperBound
        }
        return count
    }
}
