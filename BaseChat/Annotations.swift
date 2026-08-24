import SwiftUI

// MARK: - Tool state

enum AnnotationTool: Hashable {
    case none
    case mark(Annotation.Kind)   // highlight / underline / strikethrough
    case sketch
    case text
    case shape

    var kind: Annotation.Kind? {
        switch self {
        case .none: return nil
        case .mark(let kind): return kind
        case .sketch: return .sketch
        case .text: return .text
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
}

/// Which tool the toolbar has armed, which colour it draws in, and what is selected.
@Observable
@MainActor
final class AnnotationState {
    var tool: AnnotationTool = .none
    var ink: Annotation.Ink = .yellow
    var selection: Annotation.ID?
    var editing: Annotation.ID?

    func arm(_ tool: AnnotationTool) {
        self.tool = self.tool == tool ? .none : tool
        selection = nil
        editing = nil
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

    var onCreate: (Annotation) -> Void = { _ in }
    var onUpdate: (Annotation) -> Void = { _ in }
    var onDelete: (Annotation.ID) -> Void = { _ in }

    /// Set while a mark is being drawn or dragged; it shadows the stored one.
    @State private var draft: Annotation?
    @State private var dragOrigin: CGPoint?

    private var mine: [Annotation] {
        annotations.filter { $0.page == page && (renderNotes || $0.kind != .text) }
    }

    /// What to paint for a mark right now — the drag preview wins.
    private func live(_ annotation: Annotation) -> Annotation {
        draft?.id == annotation.id ? draft! : annotation
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
                .zIndex(state.selection == annotation.id ? 1 : 0)
                .onTapGesture(count: 2) {
                    guard self.live, !state.tool.isDrawing else { return }
                    state.selection = annotation.id
                    if annotation.kind == .text { state.editing = annotation.id }
                }
                .gesture(self.live && !state.tool.isDrawing ? grabGesture(annotation) : nil)
                .contextMenu {
                    if self.live {
                        Button("Delete", role: .destructive) { onDelete(annotation.id) }
                    }
                }
            }

            // Selection chrome and the inline inspector sit above every mark so
            // the handle stays grabbable even when marks overlap.
            if live, let id = state.selection, let selected = mine.first(where: { $0.id == id }) {
                selectionChrome(for: live(selected), stored: selected)
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
                    .gesture(createGesture)
            }
        }
    }

    // MARK: Creating

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let kind = state.tool.kind else { return }
                if dragOrigin == nil { dragOrigin = value.startLocation }
                let start = dragOrigin ?? value.startLocation
                var next = draft ?? Annotation(kind: kind, ink: state.ink, page: page, rect: .zero)
                next.ink = state.ink

                switch kind {
                case .highlight, .underline, .strikethrough:
                    next.bands = bands(from: start, to: value.location)
                    next.rect = Self.union(next.bands)
                case .sketch:
                    next.points.append(unit(value.location))
                    next.rect = Self.bounds(of: next.points)
                default:
                    next.rect = unitRect(from: start, to: value.location)
                }
                draft = next
            }
            .onEnded { value in
                defer { dragOrigin = nil; draft = nil }
                guard let kind = state.tool.kind else { return }
                var made = draft ?? Annotation(kind: kind, ink: state.ink, page: page, rect: .zero)
                made.ink = state.ink

                switch kind {
                case .text:
                    // A click is enough: drop a note box of a sensible default size.
                    let point = unit(value.location)
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
                default:
                    guard made.rect.width > 0.004, made.rect.height > 0.004 else { return }
                }

                onCreate(made)
                state.selection = made.id
                if kind == .text { state.editing = made.id }
                // One mark per arming. While a tool is armed the whole sheet is
                // a capture plate, which swallows clicks on the message buttons
                // and turns a click on a shape into a new shape — so put the
                // tool away as soon as it has drawn something.
                state.tool = .none
            }
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
                if state.selection != annotation.id {
                    state.selection = annotation.id
                    state.editing = nil
                }
                guard !annotation.isTextMark, moved(value.translation) else { return }
                draft = shifted(annotation, by: value.translation)
            }
            .onEnded { value in
                state.selection = annotation.id
                if !annotation.isTextMark, moved(value.translation) {
                    onUpdate(shifted(annotation, by: value.translation))
                } else if state.editing != annotation.id {
                    state.editing = nil
                }
                draft = nil
            }
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
        var moved = annotation
        let dx = (annotation.rect.minX + translation.width / size.width)
            .clamped(upper: 1 - annotation.rect.width) - annotation.rect.minX
        let dy = (annotation.rect.minY + translation.height / size.height)
            .clamped(upper: 1 - annotation.rect.height) - annotation.rect.minY
        moved.rect.origin = CGPoint(x: annotation.rect.minX + dx, y: annotation.rect.minY + dy)
        moved.bands = annotation.bands.map { $0.offsetBy(dx: dx, dy: dy) }
        moved.points = annotation.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return moved
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
            // A text mark is a run of lines, so outline each band. Drawing one
            // box around the union would claim the empty space to the right of
            // the first line and the left of the last.
            ForEach(Array(outlines(for: shown).enumerated()), id: \.offset) { _, frame in
                Rectangle()
                    .stroke(Self.outline, style: .init(lineWidth: 0.5, dash: [3, 2]))
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }

            // A selection is not an object — nothing to drag or size.
            if !stored.isTextMark {
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Self.chrome)
                        .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                        .frame(width: 8 / scale, height: 8 / scale)
                        .offset(x: corner.point(in: box).x - 4 / scale,
                                y: corner.point(in: box).y - 4 / scale)
                        .onHover { inside in
                            if inside { corner.cursor.push() } else { NSCursor.pop() }
                        }
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

    private func unitRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let start = unit(a), end = unit(b)
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
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
    static let maxWidth: CGFloat = 260

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

                if showsShapeStyle || showsType {
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
                stepper(symbol: "rectangle.roundedtop", help: "Corner radius",
                        values: [0, 2, 4, 8, 14, 22], unit: "pt") { radius in
                    var next = annotation
                    next.cornerRadius = radius
                    onUpdate(next)
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

            case .shape:
                let frame = box(annotation.rect)
                RoundedRectangle(cornerRadius: annotation.cornerRadius)
                    .fill(annotation.fillColor ?? Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: annotation.cornerRadius)
                            .stroke(annotation.strokeColor, lineWidth: annotation.lineWidth)
                    }
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
