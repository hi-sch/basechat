import SwiftUI

// MARK: - Tool state

enum AnnotationTool: Hashable {
    case none
    case mark(Annotation.Kind)   // highlight / underline / strikethrough
    case sketch
    case text
    case shape

    /// Which toolbar button owns a tool. The three text marks share one button
    /// and one options panel, so they share one family.
    enum Family: String, Hashable, Identifiable, CaseIterable {
        case mark, shape, note, sketch

        var id: String { rawValue }

        var label: String {
            switch self {
            case .mark: return "Highlight"
            case .shape: return "Shape"
            case .note: return "Note"
            case .sketch: return "Draw"
            }
        }

        var symbol: String {
            switch self {
            case .mark: return "highlighter"
            case .shape: return "square.on.circle"
            case .note: return "note.text"
            case .sketch: return "scribble"
            }
        }
    }

    var kind: Annotation.Kind? {
        switch self {
        case .none: return nil
        case .mark(let kind): return kind
        case .sketch: return .sketch
        case .text: return .text
        case .shape: return .shape
        }
    }

    var family: Family? {
        switch self {
        case .none: return nil
        case .mark: return .mark
        case .sketch: return .sketch
        case .text: return .note
        case .shape: return .shape
        }
    }

    var isDrawing: Bool { self != .none }

    /// Text marks are dragged across lines like a selection, not as a box.
    var isTextMark: Bool {
        switch self {
        case .mark: return true
        default: return false
        }
    }

    /// The pointer to show while this tool is armed, so the sheet says which
    /// one is holding it before the first drag. The text marks run along a line
    /// of type like a selection, so they take the I-beam; everything else is
    /// drawn at a point, which is what a crosshair is for.
    @MainActor var cursor: NSCursor? {
        switch self {
        case .none: return nil
        case .mark: return .iBeam
        case .shape, .text, .sketch: return .crosshair
        }
    }
}

/// Which tool the toolbar has armed, which colour it draws in, and what is selected.
@Observable
@MainActor
final class AnnotationState {
    var tool: AnnotationTool = .none
    /// Marks are selected several at a time — ⇧-click adds to the set — so a
    /// group of shapes moves and deletes as one.
    var selected: Set<Annotation.ID> = []
    var editing: Annotation.ID?

    // MARK: What each tool draws with
    //
    // Kept per tool rather than shared, so reaching for the pen does not
    // repaint the highlighter, and coming back to a tool finds it as it was
    // left. A tool's options panel edits exactly these.

    /// Colour of the text marks, and which of the three the pen draws.
    var ink: Annotation.Ink = .yellow
    var markKind: Annotation.Kind = .highlight

    var figure: Annotation.Figure = .rectangle
    var shapeInk: Annotation.Ink = .blue
    var shapeFilled = false
    var shapeWidth: Double = 2

    var noteInk: Annotation.Ink = .yellow
    var noteFontSize: Double = 12

    var sketchInk: Annotation.Ink = .pink
    var sketchWidth: Double = 2

    /// Which tool's options panel is showing, and where its button sits, so the
    /// panel can be drawn over the document right under the button that owns it.
    var options: AnnotationTool.Family?
    var anchors: [AnnotationTool.Family: CGRect] = [:]

    /// Off, a tool draws one mark and puts itself away; on, it keeps drawing
    /// until it is put away by hand. Each panel has the switch.
    var sticky = false

    /// Where the inline inspector is sitting, in page points, so the sheet's
    /// pointer owner knows that patch is chrome and not paper.
    var inspectorFrame: CGRect?

    /// Bumped whenever the page asks the header's panels to get out of the way.
    /// Model settings are not markup, but they hang off the same header and
    /// close on the same clicks, so they watch this too.
    private(set) var panelDismissals = 0

    func dismissPanels() {
        options = nil
        panelDismissals &+= 1
    }

    /// The lone selected mark, when there is exactly one. Resize handles and
    /// the inline inspector are single-object controls, so they ask for this.
    var selection: Annotation.ID? {
        get { selected.count == 1 ? selected.first : nil }
        set { selected = newValue.map { [$0] } ?? [] }
    }

    func isSelected(_ id: Annotation.ID) -> Bool { selected.contains(id) }

    func clearSelection() {
        selected.removeAll()
        editing = nil
    }

    /// A click on a toolbar button: take the tool out and open its options. A
    /// second click on the same button puts both away.
    func pick(_ tool: AnnotationTool) {
        if self.tool == tool {
            self.tool = .none
            options = nil
        } else {
            self.tool = tool
            options = tool.family
        }
        clearSelection()
    }

    /// Switch which mark the pen draws without closing its panel — the three
    /// text marks are one button.
    func setMarkKind(_ kind: Annotation.Kind) {
        markKind = kind
        tool = .mark(kind)
    }

    /// Escape, and every click that lands on the paper: give up the panel, then
    /// the selection, then the tool. One step per press, most local first.
    func retreat() -> Bool {
        if editing != nil { editing = nil; return true }
        if options != nil { options = nil; return true }
        if !selected.isEmpty { clearSelection(); return true }
        if tool != .none { tool = .none; return true }
        return false
    }

    /// A fresh mark carrying the armed tool's own colour and weight.
    func draft(kind: Annotation.Kind, page: Int) -> Annotation {
        var mark = Annotation(kind: kind, page: page, rect: .zero)
        switch kind {
        case .highlight, .underline, .strikethrough:
            mark.ink = ink
            mark.stroke = ink.shade
        case .shape:
            mark.ink = shapeInk
            mark.stroke = shapeInk.shade
            mark.fill = shapeFilled ? shapeInk.shade.opacity(0.18) : nil
            mark.lineWidth = shapeWidth
            mark.figure = figure
        case .text:
            mark.ink = noteInk
            mark.stroke = noteInk.shade
            mark.fill = noteInk.shade.opacity(0.16)
            mark.fontSize = noteFontSize
        case .sketch:
            mark.ink = sketchInk
            mark.stroke = sketchInk.shade
            mark.lineWidth = sketchWidth
        }
        return mark
    }
}

extension TextColumn {
    /// The line the pointer is on, or the closest one when it is in the gap
    /// between two or past the end of the turn.
    func lineIndex(nearest y: CGFloat) -> Int {
        if let inside = lines.firstIndex(where: { y >= $0.minY && y <= $0.maxY }) { return inside }
        var best = 0
        var distance = CGFloat.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            let gap = y < line.minY ? line.minY - y : y - line.maxY
            if gap < distance { distance = gap; best = index }
        }
        return best
    }
}

extension Annotation.Shade {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(resolved.redComponent),
                  green: Double(resolved.greenComponent),
                  blue: Double(resolved.blueComponent),
                  alpha: Double(resolved.alphaComponent))
    }
}

extension Annotation.Ink {
    var color: Color { shade.color }
}

extension Annotation {
    /// Moves box, bands and freehand path together — by a delta in page units —
    /// and keeps the whole mark on the sheet.
    func moved(dx: CGFloat, dy: CGFloat) -> Annotation {
        let x = (rect.minX + dx).clamped(upper: 1 - rect.width)
        let y = (rect.minY + dy).clamped(upper: 1 - rect.height)
        let stepX = x - rect.minX, stepY = y - rect.minY
        var next = self
        next.rect.origin = CGPoint(x: x, y: y)
        next.bands = bands.map { $0.offsetBy(dx: stepX, dy: stepY) }
        next.points = points.map { CGPoint(x: $0.x + stepX, y: $0.y + stepY) }
        return next
    }

    /// A copy with its own identity, nudged clear of the original so both are
    /// visible after a duplicate.
    func duplicated() -> Annotation {
        var copy = moved(dx: 0.012, dy: 0.012)
        copy.id = UUID()
        return copy
    }
}

extension Annotation {
    var strokeColor: Color { strokeShade.color }
    var fillColor: Color? { fillShade?.color }
}

/// A turn's text area on one sheet, in normalized page coordinates, together
/// with the measured ink box of each of its lines. The highlight tool paints
/// those boxes, so a band covers the letters and nothing else.
struct TextColumn {
    let rect: CGRect
    let lines: [CGRect]
}

// MARK: - The layer drawn over one page

struct AnnotationLayer: View {
    let page: Int
    let size: CGSize
    /// All of the chat's marks; the layer filters to its own page.
    let annotations: [Annotation]
    let state: AnnotationState
    var columns: [TextColumn] = []
    /// Interaction is off while exporting to PDF.
    var live = true
    /// The exporter turns notes into real PDF annotations instead, so it asks
    /// the layer not to paint them.
    var renderNotes = true
    /// The sheet forces a light scheme; the inspector is app chrome, so it is
    /// handed the window's real appearance and puts it back.
    var appearance: ColorScheme = .light
    /// Zoom of the sheet. The inspector divides it out so the bar keeps one
    /// size on screen no matter how far the page is zoomed.
    var scale: CGFloat = 1
    /// False when the sheet around the layer owns the pointer. Cursors do not
    /// nest — the last view to set one wins — so only one of the two decides.
    var managesPointer = true

    var onCreate: (Annotation) -> Void = { _ in }
    var onUpdate: (Annotation) -> Void = { _ in }
    var onDelete: (Annotation.ID) -> Void = { _ in }

    /// Set while a mark is being drawn; it shadows the stored one.
    @State private var draft: Annotation?
    @State private var dragOrigin: CGPoint?
    /// Preview positions for the marks travelling with the current drag —
    /// a whole selection moves together, so one shadow is not enough.
    @State private var moving: [Annotation.ID: Annotation] = [:]
    /// Which mark the pointer went down on, and whether it was already part of
    /// the selection then — a ⇧-click can only take a mark back out if it was.
    @State private var grabbed: Annotation.ID?
    @State private var grabWasSelected = false

    private var mine: [Annotation] {
        annotations.filter { $0.page == page && (renderNotes || $0.kind != .text) }
    }

    /// What to paint for a mark right now — the drag preview wins.
    private func live(_ annotation: Annotation) -> Annotation {
        if let dragged = moving[annotation.id] { return dragged }
        return draft?.id == annotation.id ? draft! : annotation
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(mine) { annotation in
                let shown = live(annotation)
                AnnotationShape(
                    annotation: shown,
                    size: size,
                    editing: self.live && state.editing == annotation.id,
                    onEdit: { text in
                        var edited = annotation
                        edited.text = text
                        onUpdate(edited)
                    }
                )
                .contentShape(hitShape(shown))
                .zIndex(state.isSelected(annotation.id) ? 1 : 0)
                // Only an idle pointer offers to pick a mark up; while a tool is
                // armed the plate below owns the cursor.
                .pointer(managesPointer && self.live && !state.tool.isDrawing
                         && !annotation.isTextMark ? NSCursor.openHand : nil,
                         token: state.tool)
                .onTapGesture(count: 2) {
                    guard self.live, !state.tool.isDrawing else { return }
                    state.selection = annotation.id
                    if annotation.kind == .text { state.editing = annotation.id }
                }
                .gesture(self.live && !state.tool.isDrawing ? grabGesture(annotation) : nil)
                .contextMenu {
                    if self.live {
                        Button("Duplicate") {
                            let copy = annotation.duplicated()
                            onCreate(copy)
                            state.selection = copy.id
                        }
                        if annotation.kind == .text {
                            Button("Edit Note") {
                                state.selection = annotation.id
                                state.editing = annotation.id
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { onDelete(annotation.id) }
                    }
                }
            }

            // Selection chrome and the inline inspector sit above every mark so
            // the handle stays grabbable even when marks overlap. Every selected
            // mark is outlined; only a lone one gets handles and an inspector.
            if live {
                ForEach(mine.filter { state.isSelected($0.id) }) { selected in
                    selectionOutline(for: self.live(selected))
                }
                if let id = state.selection, let selected = mine.first(where: { $0.id == id }) {
                    selectionChrome(for: self.live(selected), stored: selected)
                }
            }

            if let draft, !mine.contains(where: { $0.id == draft.id }) {
                AnnotationShape(annotation: draft, size: size)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // The capture plate only exists while a tool is armed, so ordinary
        // text selection in the transcript keeps working the rest of the time.
        .background {
            if live, state.tool.isDrawing {
                Color.white.opacity(0.001)
                    .contentShape(.rect)
                    .pointer(managesPointer ? state.tool.cursor : nil, token: state.tool)
                    .gesture(createGesture)
            }
        }
    }

    // MARK: Creating

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let kind = state.tool.kind else { return }
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    // The panel has said its piece; get it off the page.
                    state.dismissPanels()
                }
                let start = dragOrigin ?? value.startLocation
                var next = draft ?? state.draft(kind: kind, page: page)

                switch kind {
                case .highlight, .underline, .strikethrough:
                    next.bands = bands(from: start, to: value.location)
                    next.rect = Self.union(next.bands)
                case .sketch:
                    next.points.append(unit(value.location))
                    next.rect = Self.bounds(of: next.points)
                case .shape where next.figure.isOpen:
                    next.points = ends(from: start, to: value.location, straighten: Self.shiftHeld)
                    next.rect = Self.bounds(of: next.points)
                default:
                    next.rect = unitRect(from: start, to: value.location, square: Self.shiftHeld)
                }
                draft = next
            }
            .onEnded { value in
                defer { dragOrigin = nil; draft = nil }
                guard let kind = state.tool.kind else { return }
                var made = draft ?? state.draft(kind: kind, page: page)
                let point = unit(value.location)

                switch kind {
                case .text:
                    // A click is enough: drop a note box of a sensible default size.
                    made.rect = CGRect(x: min(point.x, 0.62), y: min(point.y, 0.94),
                                       width: 0.3, height: 0.05)
                    made.text = ""
                case .sketch:
                    guard made.points.count > 2 else { return }
                    made.rect = Self.bounds(of: made.points)
                case .highlight, .underline, .strikethrough:
                    made.bands = made.bands.filter { $0.width > 0.004 }
                    guard !made.bands.isEmpty else { return }
                    made.rect = Self.union(made.bands)
                case .shape where made.figure.isOpen:
                    // Too short to be a drag: lay a default line down instead of
                    // dropping the click on the floor.
                    if made.points.count != 2 || Self.length(made.points) < 0.02 {
                        made.points = [CGPoint(x: (point.x - 0.09).clamped(), y: point.y),
                                       CGPoint(x: (point.x + 0.09).clamped(), y: point.y)]
                    }
                    made.rect = Self.bounds(of: made.points)
                default:
                    if made.rect.width <= 0.004 || made.rect.height <= 0.004 {
                        made.rect = CGRect(x: min(point.x, 0.84), y: min(point.y, 0.9),
                                           width: 0.16, height: 0.1)
                    }
                }

                onCreate(made)
                state.selection = made.id
                if kind == .text { state.editing = made.id }
                // One mark per arming unless the tool was pinned. While a tool
                // is armed the whole sheet is a capture plate, which swallows
                // clicks on the message buttons and turns a click on a shape
                // into a new shape — so the default is to put it away as soon
                // as it has drawn something.
                if !state.sticky { state.tool = .none }
            }
    }

    /// The two ends of an open figure. ⇧ snaps the line to the nearest 45°.
    private func ends(from a: CGPoint, to b: CGPoint, straighten: Bool) -> [CGPoint] {
        let start = unit(a)
        guard straighten else { return [start, unit(b)] }
        let dx = b.x - a.x, dy = b.y - a.y
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        // How far the drag went along the direction it snapped to.
        let reach = max(0, dx * cos(angle) + dy * sin(angle))
        return [start, unit(CGPoint(x: a.x + cos(angle) * reach, y: a.y + sin(angle) * reach))]
    }

    private static func length(_ points: [CGPoint]) -> CGFloat {
        guard points.count == 2 else { return 0 }
        return hypot(points[1].x - points[0].x, points[1].y - points[0].y)
    }

    /// Turns a drag into one box per line of text, the way dragging across a
    /// paragraph in Preview does: the first line runs from the grab point to the
    /// end of its text, the last from the start of its text to the release
    /// point, and the lines between are covered end to end. The boxes are the
    /// measured ink of each line, so nothing is painted past the last word or
    /// above the tallest letter.
    private func bands(from a: CGPoint, to b: CGPoint) -> [CGRect] {
        let start = unit(a), end = unit(b)
        let (top, bottom) = start.y <= end.y ? (start, end) : (end, start)

        guard let column = column(containing: top) ?? column(containing: bottom),
              !column.lines.isEmpty
        else { return [unitRect(from: a, to: b)] }

        let first = column.lineIndex(nearest: top.y)
        let last = max(first, column.lineIndex(nearest: bottom.y))
        let pad = Paper.inkPad / Paper.height

        func box(_ index: Int, from x0: CGFloat, to x1: CGFloat) -> CGRect {
            let line = column.lines[index]
            let left = max(line.minX, min(x0, x1))
            let right = min(line.maxX, max(x0, x1))
            guard right > left else { return .zero }
            return CGRect(x: left, y: line.minY - pad,
                          width: right - left, height: line.height + pad * 2)
        }

        var result: [CGRect] = []
        if first == last {
            result = [box(first, from: top.x, to: bottom.x)]
        } else {
            result.append(box(first, from: top.x, to: column.lines[first].maxX))
            for line in (first + 1)..<last {
                result.append(box(line, from: column.lines[line].minX, to: column.lines[line].maxX))
            }
            result.append(box(last, from: column.lines[last].minX, to: bottom.x))
        }
        return result.filter { $0.width > 0 }
    }

    private func column(containing point: CGPoint) -> TextColumn? {
        columns.first { $0.rect.insetBy(dx: 0, dy: -0.01).contains(point) }
    }

    // MARK: Moving and resizing

    /// Select and move in one gesture. Two separate recognizers meant a plain
    /// click on a second mark while a first one was selected could be eaten by
    /// the drag before the tap ever fired.
    private func grabGesture(_ annotation: Annotation) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if grabbed != annotation.id {
                    grabbed = annotation.id
                    grabWasSelected = state.isSelected(annotation.id)
                    // ⇧ adds to the selection instead of replacing it.
                    if !grabWasSelected {
                        if Self.shiftHeld {
                            state.selected.insert(annotation.id)
                        } else {
                            state.selected = [annotation.id]
                        }
                        state.editing = nil
                    }
                }
                guard !annotation.isTextMark, moved(value.translation) else { return }
                moving = group(around: annotation).reduce(into: [:]) { result, mark in
                    result[mark.id] = shifted(mark, by: value.translation)
                }
            }
            .onEnded { value in
                let dragged = moved(value.translation)
                if !dragged {
                    if Self.shiftHeld {
                        // A second ⇧-click takes a mark back out of the group.
                        if grabWasSelected, state.selected.count > 1 {
                            state.selected.remove(annotation.id)
                        }
                    } else {
                        state.selected = [annotation.id]
                    }
                }
                if !annotation.isTextMark, dragged {
                    for mark in moving.values { onUpdate(mark) }
                } else if state.editing != annotation.id {
                    state.editing = nil
                }
                moving = [:]
                grabbed = nil
            }
    }

    /// The marks that travel with `annotation`: the whole selection when it is
    /// part of one, and only what is on this sheet — a mark on another page is
    /// drawn by that page's own layer, which knows nothing about this drag.
    private func group(around annotation: Annotation) -> [Annotation] {
        guard state.isSelected(annotation.id), state.selected.count > 1 else { return [annotation] }
        return mine.filter { state.isSelected($0.id) && !$0.isTextMark }
    }

    private func moved(_ translation: CGSize) -> Bool {
        abs(translation.width) > 2 || abs(translation.height) > 2
    }

    private func resizeGesture(_ annotation: Annotation, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                draft = resized(annotation, corner: corner, by: value.translation,
                                proportional: Self.shiftHeld)
            }
            .onEnded { value in
                let next = resized(annotation, corner: corner, by: value.translation,
                                   proportional: Self.shiftHeld)
                draft = nil
                onUpdate(next)
            }
    }

    /// `DragGesture.Value` carries no modifier flags, so read them live.
    private static var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func shifted(_ annotation: Annotation, by translation: CGSize) -> Annotation {
        annotation.moved(dx: translation.width / size.width, dy: translation.height / size.height)
    }

    private func resized(_ annotation: Annotation, corner: Corner, by translation: CGSize,
                         proportional: Bool = false) -> Annotation {
        var dx = translation.width / size.width
        var dy = translation.height / size.height

        // Shift locks the aspect ratio. Take whichever axis the pointer moved
        // furthest on, in page units, and derive the other from it.
        if proportional, annotation.rect.height > 0 {
            let ratio = annotation.rect.width / annotation.rect.height
            let horizontal = corner == .topLeading || corner == .bottomLeading ? -dx : dx
            let vertical = corner == .topLeading || corner == .topTrailing ? -dy : dy
            if abs(horizontal) > abs(vertical * ratio) {
                let growth = horizontal / ratio
                dy = (corner == .topLeading || corner == .topTrailing) ? -growth : growth
            } else {
                let growth = vertical * ratio
                dx = (corner == .topLeading || corner == .bottomLeading) ? -growth : growth
            }
        }

        var rect = annotation.rect

        switch corner {
        case .topLeading:
            rect.origin.x += dx; rect.origin.y += dy
            rect.size.width -= dx; rect.size.height -= dy
        case .topTrailing:
            rect.origin.y += dy
            rect.size.width += dx; rect.size.height -= dy
        case .bottomLeading:
            rect.origin.x += dx
            rect.size.width -= dx; rect.size.height += dy
        case .bottomTrailing:
            rect.size.width += dx; rect.size.height += dy
        }

        rect.size.width = max(0.02, rect.size.width)
        rect.size.height = max(0.015, rect.size.height)
        rect.origin.x = min(max(0, rect.origin.x), 1 - rect.size.width)
        rect.origin.y = min(max(0, rect.origin.y), 1 - rect.size.height)

        var next = annotation
        next.rect = rect
        if !annotation.points.isEmpty {
            next.points = Self.rescale(annotation.points, from: annotation.rect, to: rect)
        }
        return next
    }

    // MARK: Selection chrome

    /// The dashed box around a selected mark. A text mark is a run of lines, so
    /// outline each band. Drawing one box around the union would claim the empty
    /// space to the right of the first line and the left of the last.
    private func selectionOutline(for shown: Annotation) -> some View {
        ForEach(Array(outlines(for: shown).enumerated()), id: \.offset) { _, frame in
            Rectangle()
                .stroke(Self.outline, style: .init(lineWidth: 0.5, dash: [3, 2]))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func selectionChrome(for shown: Annotation, stored: Annotation) -> some View {
        let box = pixels(shown.rect).insetBy(dx: -3, dy: -3)
        // Gap and bar height are screen measurements, so they are divided by the
        // sheet's zoom to land in page coordinates.
        let gap = 4 / scale
        let barHeight = AnnotationInspector.height / scale
        let above = box.minY - barHeight - gap
        let barY = above >= 0 ? above : box.maxY + gap
        let barX = max(0, min(box.minX, size.width - AnnotationInspector.maxWidth / scale))

        ZStack(alignment: .topLeading) {
            // A selection is not an object — nothing to drag or size.
            if !stored.isTextMark {
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Self.chrome)
                        .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                        .frame(width: 8 / scale, height: 8 / scale)
                        .offset(x: corner.point(in: box).x - 4 / scale,
                                y: corner.point(in: box).y - 4 / scale)
                        .pointer(managesPointer ? corner.cursor : nil, token: state.tool)
                        .gesture(resizeGesture(stored, corner: corner))
                }
            }

            AnnotationInspector(annotation: stored,
                                appearance: appearance,
                                onUpdate: onUpdate,
                                onDelete: onDelete)
                .fixedSize()
                .scaleEffect(1 / scale, anchor: .topLeading)
                .offset(x: barX, y: barY)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                    state.inspectorFrame = CGRect(x: barX, y: barY,
                                                  width: measured.width / scale,
                                                  height: measured.height / scale)
                }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static let chrome = Color(white: 0.45)
    private static let outline = Color(white: 0.62)

    private func outlines(for annotation: Annotation) -> [CGRect] {
        guard annotation.isTextMark else {
            return [pixels(annotation.rect).insetBy(dx: -3, dy: -3)]
        }
        return annotation.paintedBands.map { pixels($0).insetBy(dx: -1.5, dy: -1.5) }
    }

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        func point(in box: CGRect) -> CGPoint {
            switch self {
            case .topLeading: return CGPoint(x: box.minX, y: box.minY)
            case .topTrailing: return CGPoint(x: box.maxX, y: box.minY)
            case .bottomLeading: return CGPoint(x: box.minX, y: box.maxY)
            case .bottomTrailing: return CGPoint(x: box.maxX, y: box.maxY)
            }
        }

        /// The system's own corner-resize pointer for this corner.
        var cursor: NSCursor {
            switch self {
            case .topLeading: return .frameResize(position: .topLeft, directions: .all)
            case .topTrailing: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeading: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomTrailing: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
    }

    private func hitShape(_ annotation: Annotation) -> Path {
        var path = Path()
        for band in annotation.paintedBands {
            path.addRect(pixels(band).insetBy(dx: -3, dy: -3))
        }
        return path
    }

    // MARK: Geometry helpers

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x / size.width).clamped(), y: (point.y / size.height).clamped())
    }

    /// The box between two points. ⇧ makes it square on screen, which is not
    /// square in page units — the sheet is taller than it is wide.
    private func unitRect(from a: CGPoint, to b: CGPoint, square: Bool = false) -> CGRect {
        var end = b
        if square {
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            end = CGPoint(x: a.x + (b.x < a.x ? -side : side),
                          y: a.y + (b.y < a.y ? -side : side))
        }
        let start = unit(a), stop = unit(end)
        return CGRect(x: min(start.x, stop.x), y: min(start.y, stop.y),
                      width: abs(stop.x - start.x), height: abs(stop.y - start.y))
    }

    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        guard var box = rects.first else { return .zero }
        for rect in rects.dropFirst() { box = box.union(rect) }
        return box
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0.001), height: max(maxY - minY, 0.001))
    }

    static func rescale(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        guard old.width > 0, old.height > 0 else { return points }
        return points.map { point in
            CGPoint(x: new.minX + (point.x - old.minX) / old.width * new.width,
                    y: new.minY + (point.y - old.minY) / old.height * new.height)
        }
    }

    static func rescale(_ rect: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        guard old.width > 0, old.height > 0 else { return rect }
        return CGRect(
            x: new.minX + (rect.minX - old.minX) / old.width * new.width,
            y: new.minY + (rect.minY - old.minY) / old.height * new.height,
            width: rect.width / old.width * new.width,
            height: rect.height / old.height * new.height
        )
    }
}

private extension CGFloat {
    func clamped(lower: CGFloat = 0, upper: CGFloat = 1) -> CGFloat {
        Swift.min(Swift.max(self, lower), Swift.max(lower, upper))
    }
}

// MARK: - Inline inspector

/// The bar that appears next to a selected mark: colour, fill, stroke, corners,
/// type size. Built from the same `ToolButton` and `PillDivider` the header
/// uses, and backed like the composer so it does not take its colour from
/// whichever sheet happens to be under it.
struct AnnotationInspector: View {
    let annotation: Annotation
    var appearance: ColorScheme = .light
    let onUpdate: (Annotation) -> Void
    let onDelete: (Annotation.ID) -> Void

    static let height: CGFloat = 28
    /// Enough to keep the widest arrangement on the sheet.
    static let maxWidth: CGFloat = 300

    private var showsStroke: Bool {
        annotation.kind == .shape || annotation.kind == .sketch
    }
    private var showsShapeStyle: Bool { annotation.kind == .shape }
    private var showsType: Bool { annotation.kind == .text }

    var body: some View {
        HStack(spacing: 2) {
            // Text marks keep the five presets — that is the Preview vocabulary.
            // Everything else gets the real colour well, opacity included.
            if annotation.isTextMark {
                ForEach(Annotation.Ink.allCases) { ink in
                    swatch(ink, selected: annotation.strokeShade == ink.shade) {
                        var next = annotation
                        next.ink = ink
                        next.stroke = ink.shade
                        onUpdate(next)
                    }
                }
            } else {
                well(icon: "NSTouchBarColorPickerStroke",
                     fallback: "pencil.tip",
                     help: "Border colour",
                     colour: annotation.strokeColor) { shade in
                    var next = annotation
                    next.stroke = shade
                    onUpdate(next)
                }

                // An open figure has no inside to fill.
                if (showsShapeStyle && !annotation.figure.isOpen) || showsType {
                    well(icon: "NSTouchBarColorPickerFill",
                         fallback: "paintbrush.fill",
                         help: "Fill colour — drop the opacity to zero for no fill",
                         colour: annotation.fillColor ?? .clear) { shade in
                        var next = annotation
                        next.fill = shade
                        onUpdate(next)
                    }
                }
            }

            if showsShapeStyle {
                PillDivider()
                Menu {
                    Picker("Shape", selection: Binding(
                        get: { annotation.figure },
                        set: { figure in
                            var next = annotation
                            next.figure = figure
                            // A box has no direction to keep; give the open
                            // figures the diagonal of the box they came from.
                            if figure.isOpen, next.points.count != 2 {
                                next.points = [CGPoint(x: next.rect.minX, y: next.rect.minY),
                                               CGPoint(x: next.rect.maxX, y: next.rect.maxY)]
                            }
                            onUpdate(next)
                        }
                    )) {
                        ForEach(Annotation.Figure.allCases) { figure in
                            Label(figure.label, systemImage: figure.symbol).tag(figure)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: annotation.figure.symbol)
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 26, height: 22)
                .help("Shape")

                if annotation.figure == .rectangle {
                    stepper(symbol: "rectangle.roundedtop", help: "Corner radius",
                            values: [0, 2, 4, 8, 14, 22], unit: "pt") { radius in
                        var next = annotation
                        next.cornerRadius = radius
                        onUpdate(next)
                    }
                }
            }

            if showsStroke {
                PillDivider()
                stepper(symbol: "lineweight", help: "Stroke width",
                        values: [1, 2, 3, 5, 8], unit: "pt") { width in
                    var next = annotation
                    next.lineWidth = width
                    onUpdate(next)
                }
            }

            if showsType {
                PillDivider()
                stepper(symbol: "textformat.size", help: "Text size",
                        values: [9, 10, 12, 14, 18, 24], unit: "pt") { size in
                    var next = annotation
                    next.fontSize = size
                    onUpdate(next)
                }
            }

            PillDivider()
            Button {
                onDelete(annotation.id)
            } label: {
                DeleteIcon()
                    .frame(width: 26, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 5)
        .frame(height: Self.height)
        .glassEffect(.regular, in: .capsule)
        .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
        .environment(\.colorScheme, appearance)
    }

    /// AppKit's stroke and fill colour-picker glyphs, sitting over the system
    /// colour well so a click opens the standard colour panel.
    private func well(icon: String, fallback: String, help: String, colour: Color,
                      set: @escaping (Annotation.Shade) -> Void) -> some View {
        ZStack {
            ColorPicker("", selection: Binding(
                get: { colour },
                set: { set(Annotation.Shade($0)) }
            ), supportsOpacity: true)
            .labelsHidden()
            .opacity(0.02)

            VStack(spacing: 1) {
                SystemGlyph(name: icon, fallback: fallback)
                    .frame(width: 13, height: 12)
                RoundedRectangle(cornerRadius: 1)
                    .fill(colour)
                    .frame(height: 3)
                    .overlay { RoundedRectangle(cornerRadius: 1).stroke(.primary.opacity(0.25), lineWidth: 0.5) }
                    .frame(width: 15)
            }
            .allowsHitTesting(false)
        }
        .frame(width: 26, height: 22)
        .help(help)
    }

    private func swatch(_ ink: Annotation.Ink, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(ink.color)
                .frame(width: 12, height: 12)
                .overlay {
                    Circle().stroke(.primary.opacity(selected ? 0.9 : 0.15),
                                    lineWidth: selected ? 1.6 : 0.8)
                }
                .frame(width: 18, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(ink.label)
    }

    private func stepper(symbol: String, help: String, values: [Double], unit: String,
                         action: @escaping (Double) -> Void) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button("\(Int(value)) \(unit)") { action(value) }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 22)
        .help(help)
    }
}

// MARK: - Pointers

/// One owner for the pointer over a sheet.
///
/// Cursors do not nest. A view that sets one on hover knows nothing about the
/// views above and below it, and whichever fires last wins — which is how the
/// I-beam over message text came to paint over an armed tool's crosshair. So
/// over a sheet exactly one place decides, on every mouse move, reading the
/// live state: the armed tool first, then a resize handle, then a mark that can
/// be picked up, then the type, then the paper.
struct MarkupPointer: ViewModifier {
    let state: AnnotationState
    /// Every mark in the chat; the owner filters to its own sheet.
    let annotations: [Annotation]
    let page: Int
    let size: CGSize
    /// Sheet zoom. Handles keep one size on screen, so the radius that catches
    /// one is divided by it, exactly as their drawing is.
    var scale: CGFloat = 1
    /// Where this sheet's type sits, in page points.
    var text: [CGRect] = []
    var live = true

    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .local) { phase in
            guard live else { return }
            switch phase {
            case .active(let point): cursor(at: point).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    private var mine: [Annotation] { annotations.filter { $0.page == page } }

    private func cursor(at point: CGPoint) -> NSCursor {
        if let armed = state.tool.cursor { return armed }

        // A lone selection is the only thing that wears handles and an
        // inspector, and both belong to the sheet it is on — which is why they
        // are read here and not from a frame that might be another page's.
        if let id = state.selection, let mark = mine.first(where: { $0.id == id }) {
            // The inspector is app chrome floating over the page: it is not
            // type and not a mark, whatever happens to be behind it.
            if let bar = state.inspectorFrame, bar.contains(point) { return .arrow }

            if !mark.isTextMark {
                let box = pixels(mark.rect).insetBy(dx: -3, dy: -3)
                let catches = 6 / scale
                for corner in AnnotationLayer.Corner.allCases {
                    let handle = corner.point(in: box)
                    if hypot(point.x - handle.x, point.y - handle.y) <= catches {
                        return corner.cursor
                    }
                }
            }
        }

        let overMark = mine.contains { mark in
            !mark.isTextMark && mark.paintedBands.contains {
                pixels($0).insetBy(dx: -3, dy: -3).contains(point)
            }
        }
        if overMark { return .openHand }

        return text.contains(where: { $0.contains(point) }) ? .iBeam : .arrow
    }

    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }
}

extension View {
    func markupPointer(state: AnnotationState, annotations: [Annotation], page: Int,
                       size: CGSize, scale: CGFloat = 1, text: [CGRect] = [],
                       live: Bool = true) -> some View {
        modifier(MarkupPointer(state: state, annotations: annotations, page: page,
                               size: size, scale: scale, text: text, live: live))
    }
}

/// Set on the sheets, where `MarkupPointer` decides the cursor, so the views
/// inside them stop setting their own.
struct MarkupOwnsPointerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markupOwnsPointer: Bool {
        get { self[MarkupOwnsPointerKey.self] }
        set { self[MarkupOwnsPointerKey.self] = newValue }
    }
}

/// Pushes a cursor while the pointer is inside, and — the part `onHover` alone
/// gets wrong — pops it again when the cursor itself changes under a pointer
/// that never left, which is what happens when a tool is swapped mid-hover.
private struct Pointer<Token: Equatable>: ViewModifier {
    let cursor: NSCursor?
    let token: Token

    @State private var inside = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside = $0; settle() }
            .onChange(of: token) { _, _ in
                // Pop first: the stack is a stack, and the old cursor is on it.
                if pushed { NSCursor.pop(); pushed = false }
                settle()
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }

    private func settle() {
        let want = inside && cursor != nil
        guard want != pushed else { return }
        if want { cursor?.push() } else { NSCursor.pop() }
        pushed = want
    }
}

extension View {
    /// `token` is whatever makes `cursor` change — the modifier watches it so a
    /// swap is not missed while the pointer sits still.
    func pointer<Token: Equatable>(_ cursor: NSCursor?, token: Token) -> some View {
        modifier(Pointer(cursor: cursor, token: token))
    }
}

/// An AppKit template image when there is one, an SF Symbol when there is not.
struct SystemGlyph: View {
    let name: String
    var fallback: String

    var body: some View {
        if let image = NSImage(named: NSImage.Name(name)) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallback)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// AppKit's own delete glyph, so the bar does not mix an SF Symbol trash in
/// beside the system-drawn controls.
struct DeleteIcon: View {
    var body: some View {
        SystemGlyph(name: "NSTouchBarDeleteTemplate", fallback: "trash")
            .frame(width: 15, height: 15)
    }
}

// MARK: - Drawing one mark

struct AnnotationShape: View {
    let annotation: Annotation
    let size: CGSize
    var editing = false
    var onEdit: (String) -> Void = { _ in }

    private func box(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    var body: some View {
        Group {
            switch annotation.kind {
            case .highlight:
                ForEach(Array(annotation.paintedBands.enumerated()), id: \.offset) { _, band in
                    let frame = box(band)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(annotation.strokeColor.opacity(0.42))
                        .blendMode(.multiply)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

            case .underline:
                ForEach(Array(annotation.paintedBands.enumerated()), id: \.offset) { _, band in
                    let frame = box(band)
                    Rectangle()
                        .fill(annotation.strokeColor)
                        .frame(width: frame.width, height: 1.5)
                        .offset(x: frame.minX, y: frame.maxY - 2.5)
                }

            case .strikethrough:
                ForEach(Array(annotation.paintedBands.enumerated()), id: \.offset) { _, band in
                    let frame = box(band)
                    Rectangle()
                        .fill(annotation.strokeColor)
                        .frame(width: frame.width, height: 1.5)
                        .offset(x: frame.minX, y: frame.midY - 0.75)
                }

            case .sketch:
                SketchPath(points: annotation.points, size: size)
                    .stroke(annotation.strokeColor,
                            style: .init(lineWidth: annotation.lineWidth,
                                         lineCap: .round, lineJoin: .round))

            case .shape where annotation.figure.isOpen:
                OpenFigure(points: annotation.points,
                           head: annotation.figure == .arrow,
                           size: size,
                           lineWidth: annotation.lineWidth)
                    .stroke(annotation.strokeColor,
                            style: .init(lineWidth: annotation.lineWidth,
                                         lineCap: .round, lineJoin: .round))

            case .shape:
                let frame = box(annotation.rect)
                let outline = FigureShape(figure: annotation.figure,
                                          cornerRadius: annotation.cornerRadius)
                outline
                    .fill(annotation.fillColor ?? Color.clear)
                    .overlay { outline.stroke(annotation.strokeColor, lineWidth: annotation.lineWidth) }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

            case .text:
                let frame = box(annotation.rect)
                NoteBox(annotation: annotation, editing: editing, onEdit: onEdit)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The outline of a closed figure, drawn to fill its box.
struct FigureShape: Shape {
    let figure: Annotation.Figure
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        switch figure {
        case .rectangle:
            let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
            return Path(roundedRect: rect, cornerRadius: max(0, radius))
        case .ellipse:
            return Path(ellipseIn: rect)
        case .triangle:
            return polygon([CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], in: rect)
        case .diamond:
            return polygon([CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5),
                            CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)], in: rect)
        case .star:
            return polygon(Self.star, in: rect)
        case .line, .arrow:
            return Path()
        }
    }

    private func polygon(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        path.move(to: place(first))
        for point in points.dropFirst() { path.addLine(to: place(point)) }
        path.closeSubpath()
        return path
    }

    /// Ten alternating points on two circles, starting at the top.
    private static let star: [CGPoint] = (0..<10).map { step in
        let radius: CGFloat = step.isMultiple(of: 2) ? 0.5 : 0.21
        let angle = -CGFloat.pi / 2 + CGFloat(step) * .pi / 5
        return CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
    }
}

/// A line between two ends, with an arrow head when it is an arrow. Ends are
/// normalized to the page, so the figure keeps the diagonal it was drawn on.
private struct OpenFigure: Shape {
    let points: [CGPoint]
    let head: Bool
    let size: CGSize
    let lineWidth: CGFloat

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let from = CGPoint(x: points[0].x * size.width, y: points[0].y * size.height)
        let to = CGPoint(x: points[1].x * size.width, y: points[1].y * size.height)
        path.move(to: from)
        path.addLine(to: to)

        guard head else { return path }
        let angle = atan2(to.y - from.y, to.x - from.x)
        let reach = max(7, lineWidth * 3.5)
        let spread = CGFloat.pi * 0.82
        for side in [spread, -spread] {
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + cos(angle + side) * reach,
                                     y: to.y + sin(angle + side) * reach))
        }
        return path
    }
}

private struct SketchPath: Shape {
    let points: [CGPoint]
    let size: CGSize

    func path(in _: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * size.width, y: point.y * size.height)
        }
        path.move(to: place(first))
        // Midpoint smoothing — a raw polyline of mouse samples looks jagged.
        for index in 1..<max(points.count, 1) {
            let previous = place(points[index - 1])
            let current = place(points[index])
            let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: middle, control: previous)
        }
        if let last = points.last { path.addLine(to: place(last)) }
        return path
    }
}

private struct NoteBox: View {
    let annotation: Annotation
    let editing: Bool
    let onEdit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(annotation.fillColor ?? annotation.strokeColor.opacity(0.16))
            RoundedRectangle(cornerRadius: 5)
                .stroke(annotation.strokeColor.opacity(0.8), lineWidth: annotation.lineWidth * 0.5)
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: annotation.fontSize))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .onChange(of: draft) { _, new in onEdit(new) }
            } else {
                Text(annotation.text.isEmpty ? "Note" : annotation.text)
                    .font(.system(size: annotation.fontSize))
                    .foregroundStyle(annotation.text.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
            }
        }
        .onAppear { draft = annotation.text }
    }
}

// MARK: - Keys over the document

/// The keyboard half of editing marks: ⌫ deletes the selection, the arrows
/// nudge it, ⌘D duplicates it.
///
/// Menu items carrying those key equivalents look like the tidy way to do this,
/// but a `Commands` body is not a view: it does not re-read the observable
/// selection, so the items stayed disabled and the keys never reached them. A
/// local monitor sees them before the menu does and decides on live state — and
/// gets out of the way whenever a caret is in a field.
struct MarkupKeys: ViewModifier {
    let state: AnnotationState
    let delete: () -> Void
    /// Distance in points on the page, already scaled by whether ⇧ was held.
    let nudge: (CGSize) -> Void
    let duplicate: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard state.editing == nil, !state.selected.isEmpty, !Self.isTyping
                    else { return event }

                    if Self.isDelete(event) {
                        delete()
                        return nil
                    }
                    if event.charactersIgnoringModifiers == "d",
                       event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                        duplicate()
                        return nil
                    }
                    if let step = Self.arrow(event) {
                        // ⇧ takes the big step, the way it does in every canvas.
                        let far: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                        nudge(CGSize(width: step.width * far, height: step.height * far))
                        return nil
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// 51 is ⌫; 117 is the ⌦ of a full keyboard. ⌘⌫ belongs to whatever else
    /// wants it — moving a file to the trash, say — so it is left alone.
    private static func isDelete(_ event: NSEvent) -> Bool {
        (event.keyCode == 51 || event.keyCode == 117)
            && !event.modifierFlags.contains(.command)
    }

    private static func arrow(_ event: NSEvent) -> CGSize? {
        guard !event.modifierFlags.contains(.command) else { return nil }
        switch event.keyCode {
        case 123: return CGSize(width: -1, height: 0)
        case 124: return CGSize(width: 1, height: 0)
        case 125: return CGSize(width: 0, height: 1)
        case 126: return CGSize(width: 0, height: -1)
        default: return nil
        }
    }

    /// True while the caret is in a field or a note: the composer, the search
    /// field and an open note all keep their own keys.
    private static var isTyping: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }
}

extension View {
    func markupKeys(_ state: AnnotationState,
                    delete: @escaping () -> Void,
                    nudge: @escaping (CGSize) -> Void,
                    duplicate: @escaping () -> Void) -> some View {
        modifier(MarkupKeys(state: state, delete: delete, nudge: nudge, duplicate: duplicate))
    }
}
