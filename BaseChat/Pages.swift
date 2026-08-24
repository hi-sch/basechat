import AppKit
import SwiftUI

// MARK: - Paper metrics

enum Paper {
    /// US Letter at 72 dpi — what the PDF exporter writes too.
    static let width: CGFloat = 612
    static let height: CGFloat = 792
    /// Tight, but still inside every printer's unprintable border.
    static let margin: CGFloat = 40
    /// Room for the running footer.
    static let footer: CGFloat = 26
    static let gutter: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    /// Grey left of the first sheet and right of it — `design_insp_3`.
    static let sideGutter: CGFloat = 14
    /// Body type in the document. Everything else scales off this.
    static let bodySize: CGFloat = 11
    /// Breathing room around the ink of a line when a highlight is painted.
    static let inkPad: CGFloat = 1

    static var contentWidth: CGFloat { width - margin * 2 }
    static var contentHeight: CGFloat { height - margin * 2 - footer }
}

/// Where the glyphs of a turn actually sit.
///
/// Font metrics describe a line box, not the marks in it, and a line box is
/// wider than the words on it and taller than their tallest letter. Both of
/// those show up immediately in a highlight — a band that clips the top of a
/// "P", or one that paints the empty half of a short line. So render the turn
/// once and look: dark pixels are text, everything else is not.
@MainActor
enum InkMap {

    struct Key: Hashable {
        let text: String
        let role: Message.Role
        let width: CGFloat
        let size: CGFloat
    }

    private static var cache: [Key: [CGRect]] = [:]
    private static var order: [Key] = []
    private static let limit = 200

    /// One rectangle per line of text, in points from the turn's top-left.
    static func lines(of message: Message, width: CGFloat = Paper.contentWidth) -> [CGRect] {
        let key = Key(text: message.text, role: message.role, width: width, size: Paper.bodySize)
        if let known = cache[key] { return known }
        let found = scan(message, width: width)
        cache[key] = found
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return found
    }

    private static func scan(_ message: Message, width: CGFloat) -> [CGRect] {
        let block = ZStack(alignment: .topLeading) {
            Color.white
            MessageBlock(message: message, highlight: "",
                         baseSize: Paper.bodySize, document: true)
        }
        .frame(width: width, alignment: .topLeading)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: block)
        let sample: CGFloat = 2
        renderer.scale = sample
        guard let image = renderer.cgImage, image.width > 0, image.height > 0 else { return [] }

        let pixelWidth = image.width
        let pixelHeight = image.height
        // Owned storage rather than an inout array: the context outlives the
        // call that would lend it the array's buffer.
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelWidth * pixelHeight)
        raw.initialize(repeating: 0, count: pixelWidth * pixelHeight)
        defer { raw.deallocate() }

        guard let context = CGContext(
            data: raw, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Text is near black; bubble fills, code backgrounds and the metadata
        // row are all much lighter, so a mid threshold separates them.
        let threshold: UInt8 = 120
        var rowFirst = [Int](repeating: -1, count: pixelHeight)
        var rowLast = [Int](repeating: -1, count: pixelHeight)
        for y in 0..<pixelHeight {
            let base = y * pixelWidth
            var first = -1, last = -1
            for x in 0..<pixelWidth where raw[base + x] < threshold {
                if first < 0 { first = x }
                last = x
            }
            rowFirst[y] = first
            rowLast[y] = last
        }

        // Rows with ink, grouped into lines. A single blank row is a gap inside
        // a line of type, not a break between two of them.
        var lines: [CGRect] = []
        var y = 0
        while y < pixelHeight {
            guard rowFirst[y] >= 0 else { y += 1; continue }
            var top = y, bottom = y
            var left = rowFirst[y], right = rowLast[y]
            var blanks = 0
            var probe = y + 1
            while probe < pixelHeight, blanks < 2 {
                if rowFirst[probe] >= 0 {
                    blanks = 0
                    bottom = probe
                    left = min(left, rowFirst[probe])
                    right = max(right, rowLast[probe])
                } else {
                    blanks += 1
                }
                probe += 1
            }
            let box = CGRect(x: CGFloat(left) / sample,
                             y: CGFloat(top) / sample,
                             width: CGFloat(right - left + 1) / sample,
                             height: CGFloat(bottom - top + 1) / sample)
            // The renderer leaves a hairline along the bottom edge of the image;
            // no line of type is under two points tall.
            if box.height >= 2 { lines.append(box) }
            y = bottom + 1
        }
        return lines
    }
}

/// One turn placed on one sheet. `y` is measured from the top of that sheet's
/// content box and goes negative for the continuation of a turn that started
/// on an earlier sheet.
struct Placement: Identifiable {
    let message: Message
    let y: CGFloat
    /// Measured height of the whole turn, used to snap highlights to its lines.
    let height: CGFloat
    /// Which slice of a turn that spans sheets this is.
    let fragment: Int
    /// Stable across repagination — an id derived from `y` changes on every
    /// height measurement, which tears the row down in the middle of a click.
    var id: String { "\(message.id)#\(fragment)" }
}

extension Paper {

    /// Greedy pagination: a turn that will not fit in what is left of the sheet
    /// starts the next one. A turn taller than a whole sheet is the exception —
    /// there is nowhere to push it, so it flows across sheets instead of being
    /// clipped, exactly like a long paragraph in a word processor.
    static func paginate(_ messages: [Message], heights: [Message.ID: CGFloat]) -> [[Placement]] {
        var pages: [[Placement]] = []
        var page: [Placement] = []
        var cursor: CGFloat = 0   // bottom edge of what is already on `page`

        func flush() {
            pages.append(page)
            page = []
            cursor = 0
        }

        for message in messages {
            let height = heights[message.id] ?? 0
            var top = page.isEmpty ? 0 : cursor + rowSpacing

            if height <= contentHeight {
                if !page.isEmpty, top + height > contentHeight {
                    flush()
                    top = 0
                }
                page.append(Placement(message: message, y: top, height: height, fragment: 0))
                cursor = top + height
                continue
            }

            // Taller than a sheet. Start it on a fresh one unless we are already
            // near the top, then let it spill over as many sheets as it needs.
            if !page.isEmpty, top > contentHeight * 0.25 {
                flush()
                top = 0
            }
            var offset = top
            var fragment = 0
            while true {
                page.append(Placement(message: message, y: offset, height: height, fragment: fragment))
                if offset + height <= contentHeight { break }
                flush()
                offset -= contentHeight
                fragment += 1
            }
            cursor = offset + height
        }

        if !page.isEmpty || pages.isEmpty { pages.append(page) }
        return pages
    }
}

/// Measured turn heights, shared by the on-screen document and the PDF exporter
/// so both paginate to exactly the same page breaks.
@Observable
@MainActor
final class DocumentLayout {
    var heights: [Message.ID: CGFloat] = [:]
    /// What each stored height was measured from, so a turn is only re-measured
    /// when its text really changed — during a reply that is the tail alone.
    private var measured: [Message.ID: Int] = [:]

    func pages(_ messages: [Message]) -> [[Placement]] {
        Paper.paginate(messages, heights: heights)
    }

    func needsMeasuring(_ message: Message) -> Bool {
        measured[message.id] != message.text.hashValue || heights[message.id] == nil
    }

    func record(_ height: CGFloat, for message: Message) {
        guard needsMeasuring(message) || abs((heights[message.id] ?? -1) - height) > 0.5 else { return }
        heights[message.id] = height
        measured[message.id] = message.text.hashValue
    }
}

// MARK: - The document

struct PagedTranscript: View {
    @Environment(\.colorScheme) private var appearance
    let chat: Chat?
    let layout: DocumentLayout
    let highlight: String
    let state: AnnotationState
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }
    var onCreate: (Annotation) -> Void = { _ in }
    var onUpdate: (Annotation) -> Void = { _ in }
    var onDelete: (Annotation.ID) -> Void = { _ in }

    /// Which chat the scroll handlers are following, so switching chats is not
    /// mistaken for a message being sent.
    @State private var following: Chat.ID?
    @State private var position = ScrollPosition(idType: Int.self)

    private var messages: [Message] { chat?.messages ?? [] }
    private var pages: [[Placement]] { layout.pages(messages) }

    /// Where a turn's first or last fragment sits, and on which sheet.
    private func locate(_ message: Message, last: Bool, in pages: [[Placement]]) -> (page: Int, placement: Placement)? {
        let sheets = Array(pages.enumerated())
        for (index, page) in (last ? sheets.reversed() : sheets) {
            let match = last ? page.last { $0.message.id == message.id }
                             : page.first { $0.message.id == message.id }
            if let match { return (index, match) }
        }
        return nil
    }

    /// Distance from the top of the scroll content to a fragment's top edge.
    private func documentY(page: Int, placement: Placement, scale: CGFloat) -> CGFloat {
        Paper.sideGutter * 2
            + CGFloat(page) * (Paper.height * scale + Paper.gutter)
            + (Paper.margin + placement.y) * scale
    }

    var body: some View {
        GeometryReader { geometry in
            // Fit-width, like Preview: the sheet keeps only a hairline of grey
            // on either side. Capped so a very wide window does not blow the
            // type up past legibility.
            let scale = min(2.0, max(0.35, (geometry.size.width - Paper.sideGutter * 2) / Paper.width))
            ScrollView {
                LazyVStack(spacing: Paper.gutter) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        PageView(
                            index: index,
                            total: pages.count,
                            title: chat?.title ?? "",
                            placements: page,
                            annotations: chat?.annotations ?? [],
                            state: state,
                            highlight: highlight,
                            appearance: appearance,
                            scale: scale,
                            onRegenerate: onRegenerate,
                            onOpenInPages: onOpenInPages,
                            onCreate: onCreate,
                            onUpdate: onUpdate,
                            onDelete: onDelete
                        )
                        .scaleEffect(scale)
                        .frame(width: Paper.width * scale, height: Paper.height * scale)
                        .id(index)
                    }
                }
                // Twice the side gutter above the first sheet and below the last.
                .padding(.vertical, Paper.sideGutter * 2)
                .frame(maxWidth: .infinity)
            }
            // Offsets rather than view ids: the turns live inside a scaled sheet,
            // where ScrollViewReader cannot find them, and the positions we want
            // fall straight out of the pagination anyway.
            .scrollPosition($position)
            .onChange(of: messages.last?.text) { _, _ in
                follow(viewport: geometry.size.height, scale: scale)
            }
            // Sending appends the prompt and then the empty reply, so the count
            // moves by one or two. Anything larger is a chat switch.
            .onChange(of: messages.count) { old, new in
                guard following == chat?.id, new > old, new - old <= 2 else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    showPrompt(scale: scale)
                }
            }
            .onChange(of: chat?.id) { _, new in
                following = new
                alignToTop()
            }
            // Start with the first sheet's top edge flush to the window, so the
            // grey band above it is scrolled away.
            .onAppear {
                following = chat?.id
                alignToTop()
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .background { ruler }
        }
    }

    // MARK: Scrolling

    private func alignToTop() {
        position.scrollTo(y: Paper.sideGutter * 2)
    }

    /// Brings the prompt that started the current exchange to the top.
    private func showPrompt(scale: CGFloat) {
        guard let prompt = messages.last(where: { $0.role == .user }),
              let at = locate(prompt, last: false, in: pages)
        else { return }
        position.scrollTo(y: documentY(page: at.page, placement: at.placement, scale: scale) - Paper.gutter)
    }

    /// Leaves the prompt at the top while the reply still fits underneath it,
    /// then follows the reply's tail so the newest words sit above the composer.
    private func follow(viewport: CGFloat, scale: CGFloat) {
        let sheets = pages
        guard let prompt = messages.last(where: { $0.role == .user }),
              let tail = messages.last,
              let promptAt = locate(prompt, last: false, in: sheets),
              let tailAt = locate(tail, last: true, in: sheets)
        else { return }

        let promptTop = documentY(page: promptAt.page, placement: promptAt.placement, scale: scale)
        let tailBottom = documentY(page: tailAt.page, placement: tailAt.placement, scale: scale)
            + tailAt.placement.height * scale

        if tailBottom - promptTop > viewport - Paper.gutter * 2 {
            position.scrollTo(y: tailBottom - viewport + Paper.gutter * 2)
        } else {
            position.scrollTo(y: promptTop - Paper.gutter)
        }
    }

    /// Off-screen pass that measures every turn at the sheet's content width.
    /// Backgrounds do not contribute to layout, so this costs nothing visually.
    private var ruler: some View {
        VStack(spacing: 0) {
            ForEach(messages.filter(layout.needsMeasuring)) { message in
                MessageBlock(message: message, highlight: "",
                             baseSize: Paper.bodySize, document: true)
                    .frame(width: Paper.contentWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        layout.record(height, for: message)
                    }
            }
        }
        .frame(width: Paper.contentWidth)
        .hidden()
    }
}

// MARK: - One sheet

struct PageView: View {
    let index: Int
    let total: Int
    let title: String
    let placements: [Placement]
    let annotations: [Annotation]
    let state: AnnotationState
    var highlight: String = ""
    /// The window's real appearance — the sheet itself is always light paper.
    var appearance: ColorScheme = .light
    /// Sheet zoom, so chrome that must not zoom can divide it out.
    var scale: CGFloat = 1
    var live = true
    var renderNotes = true
    var onRegenerate: (Message) -> Void = { _ in }
    var onOpenInPages: (Message) -> Void = { _ in }
    var onCreate: (Annotation) -> Void = { _ in }
    var onUpdate: (Annotation) -> Void = { _ in }
    var onDelete: (Annotation.ID) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Bottom of the stack, so a click only reaches the paper when it
            // missed every mark and every button above it — which is exactly
            // when the selection should be dropped.
            Color.white
                .onTapGesture {
                    guard live, !state.tool.isDrawing else { return }
                    state.selection = nil
                    state.editing = nil
                }

            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    MessageBlock(message: placement.message,
                                 highlight: highlight,
                                 baseSize: Paper.bodySize,
                                 document: true,
                                 onRegenerate: onRegenerate,
                                 onOpenInPages: onOpenInPages)
                        .frame(width: Paper.contentWidth, alignment: .topLeading)
                        // The scroll target has to be the turn's own bounds. On
                        // the cell below it, "scroll to bottom" means the bottom
                        // of the sheet, which is why the view jumped around.
                        .id(placement.id)
                        .padding(.top, placement.y)
                        .frame(width: Paper.contentWidth,
                               height: Paper.contentHeight,
                               alignment: .topLeading)
                }
            }
            .frame(width: Paper.contentWidth, height: Paper.contentHeight, alignment: .topLeading)
            .clipped()
            .padding(.horizontal, Paper.margin)
            .padding(.top, Paper.margin)

            footer

            AnnotationLayer(
                page: index,
                size: CGSize(width: Paper.width, height: Paper.height),
                annotations: annotations,
                state: state,
                columns: textColumns,
                live: live,
                renderNotes: renderNotes,
                appearance: appearance,
                scale: scale,
                onCreate: onCreate,
                onUpdate: onUpdate,
                onDelete: onDelete
            )
        }
        .frame(width: Paper.width, height: Paper.height, alignment: .topLeading)
        .clipped()
        // Pages are paper: they stay white whatever the app appearance is.
        .environment(\.colorScheme, .light)
        .shadow(color: .black.opacity(live ? 0.35 : 0), radius: live ? 5 : 0, y: live ? 2 : 0)
    }

    /// Where every line of text on this sheet actually is, normalized to the
    /// page, so the highlight tool can hug the glyphs. Only measured while a
    /// text tool is armed — scanning is cheap once and cached, but there is no
    /// reason to pay for it just to look at the page.
    private var textColumns: [TextColumn] {
        guard live, state.tool.isTextMark else { return [] }
        return placements.map { placement in
            let lines = InkMap.lines(of: placement.message).map { line in
                CGRect(x: (Paper.margin + line.minX) / Paper.width,
                       y: (Paper.margin + placement.y + line.minY) / Paper.height,
                       width: line.width / Paper.width,
                       height: line.height / Paper.height)
            }
            return TextColumn(
                rect: CGRect(x: Paper.margin / Paper.width,
                             y: (Paper.margin + placement.y) / Paper.height,
                             width: Paper.contentWidth / Paper.width,
                             height: placement.height / Paper.height),
                lines: lines
            )
        }
    }

    private var footer: some View {
        HStack {
            Text(title)
                .lineLimit(1)
            Spacer()
            Text("\(index + 1) / \(total)")
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .foregroundStyle(.black.opacity(0.35))
        .padding(.horizontal, Paper.margin)
        .frame(width: Paper.width, height: Paper.footer, alignment: .bottom)
        .offset(y: Paper.height - Paper.margin - Paper.footer + 6)
    }
}
