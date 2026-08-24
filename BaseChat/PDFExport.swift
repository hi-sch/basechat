import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Writes the paginated transcript — annotations and all — to a real PDF.
/// `ImageRenderer` hands SwiftUI a `CGContext`, so the pages come out as
/// vectors and selectable text rather than a screenshot.
@MainActor
enum PDFExport {

    static func data(for chat: Chat, layout: DocumentLayout, state: AnnotationState) -> Data? {
        let pages = layout.pages(chat.messages)
        guard !pages.isEmpty else { return nil }

        let store = NSMutableData()
        guard let consumer = CGDataConsumer(data: store) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: Paper.width, height: Paper.height)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: chat.title,
            kCGPDFContextCreator as String: "BaseChat",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            return nil
        }

        for (index, page) in pages.enumerated() {
            let sheet = PageView(
                index: index,
                total: pages.count,
                title: chat.title,
                placements: page,
                annotations: chat.annotations,
                state: state,
                live: false,
                renderNotes: false
            )

            let renderer = ImageRenderer(content: sheet)
            renderer.proposedSize = ProposedViewSize(width: Paper.width, height: Paper.height)
            renderer.render { _, draw in
                context.beginPage(mediaBox: &mediaBox)
                draw(context)
                context.endPage()
            }
        }
        context.closePDF()
        return annotated(store as Data, with: chat.annotations)
    }

    /// Turns every note into a real PDF text annotation, so it opens as a note
    /// in Preview or Acrobat instead of being a picture of one.
    private static func annotated(_ pdf: Data, with annotations: [Annotation]) -> Data {
        let notes = annotations.filter { $0.kind == .text }
        guard !notes.isEmpty, let document = PDFDocument(data: pdf) else { return pdf }

        for note in notes {
            guard let page = document.page(at: note.page) else { continue }
            // PDF pages measure from the bottom left; ours measure from the top.
            let icon = CGRect(
                x: note.rect.minX * Paper.width,
                y: Paper.height - note.rect.minY * Paper.height - 20,
                width: 20,
                height: 20
            )
            let mark = PDFAnnotation(bounds: icon, forType: .text, withProperties: nil)
            mark.contents = note.text
            mark.color = NSColor(note.ink.color)
            mark.iconType = .note
            page.addAnnotation(mark)
        }
        return document.dataRepresentation() ?? pdf
    }

    /// Asks where to put it, writes it, and reveals it in the Finder.
    static func run(for chat: Chat, layout: DocumentLayout, state: AnnotationState) {
        guard let pdf = data(for: chat, layout: layout, state: state) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = Self.filename(for: chat)
        panel.canCreateDirectories = true
        panel.title = "Export PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pdf.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func filename(for chat: Chat) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = chat.title.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Conversation" : trimmed) + ".pdf"
    }
}
