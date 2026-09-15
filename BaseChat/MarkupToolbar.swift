import SwiftUI

// MARK: - The markup buttons in the header

/// Highlighter, shape, note and pen. Every button does the same two things: it
/// takes its tool out, and it opens that tool's options right under itself — so
/// picking a colour or a shape is one click away and never a hunt through a
/// menu. A second click puts both away.
struct MarkupTools: View {
    @Bindable var state: AnnotationState
    /// Marks whatever the transcript already has selected, and says whether
    /// there was anything to mark.
    var highlightSelection: () -> Bool = { false }

    var body: some View {
        Pill {
            ForEach(AnnotationTool.Family.allCases) { family in
                button(family)
            }
        }
    }

    private func button(_ family: AnnotationTool.Family) -> some View {
        ToolButton(symbol: symbol(family),
                   help: help(family),
                   active: state.tool.family == family) {
            tap(family)
        }
        // The panel is drawn over the document, not in the header, so it needs
        // to be told where its button ended up.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            state.anchors[family] = frame
        }
    }

    private func tap(_ family: AnnotationTool.Family) {
        // Select text, then reach for the highlighter: the click means "mark
        // that", not "hand me the pen".
        if family == .mark, state.tool.family != .mark, highlightSelection() { return }
        state.pick(tool(for: family))
    }

    private func tool(for family: AnnotationTool.Family) -> AnnotationTool {
        switch family {
        case .mark: return .mark(state.markKind)
        case .shape: return .shape
        case .note: return .text
        case .sketch: return .sketch
        }
    }

    /// The pen button wears whichever of the three marks it is set to draw.
    private func symbol(_ family: AnnotationTool.Family) -> String {
        guard family == .mark else { return family.symbol }
        return MarkStyle(state.markKind).symbol
    }

    private func help(_ family: AnnotationTool.Family) -> String {
        guard family == .mark else { return family.label }
        return "\(MarkStyle(state.markKind).label) — marks the selected text, or drag across some"
    }
}

/// The three things the pen can draw, as one switchable thing.
struct MarkStyle: Hashable, Identifiable {
    let kind: Annotation.Kind

    init(_ kind: Annotation.Kind) { self.kind = kind }

    var id: String { kind.rawValue }

    static let all = [MarkStyle(.highlight), MarkStyle(.underline), MarkStyle(.strikethrough)]

    var label: String {
        switch kind {
        case .underline: return "Underline"
        case .strikethrough: return "Strike-through"
        default: return "Highlight"
        }
    }

    var symbol: String {
        switch kind {
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        default: return "highlighter"
        }
    }
}

// MARK: - One tool's options

/// The panel under a tool's button: everything that tool draws with, in one
/// click's reach. It is a plain view over the document rather than a popover
/// because a popover eats the click that dismisses it — and that click is
/// nearly always the first stroke.
struct ToolOptions: View {
    @Bindable var state: AnnotationState
    let family: AnnotationTool.Family

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch family {
            case .mark:
                row("Style") {
                    ForEach(MarkStyle.all) { style in
                        choice(symbol: style.symbol,
                               label: style.label,
                               on: state.markKind == style.kind) {
                            state.setMarkKind(style.kind)
                        }
                    }
                }
                swatches($state.ink)

            case .shape:
                row("Shape") {
                    ForEach(Annotation.Figure.allCases) { figure in
                        choice(symbol: figure.symbol,
                               label: figure.label,
                               on: state.figure == figure) {
                            state.figure = figure
                        }
                    }
                }
                swatches($state.shapeInk)
                HStack(spacing: 10) {
                    weights($state.shapeWidth)
                    if !state.figure.isOpen {
                        Toggle("Fill", isOn: $state.shapeFilled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                    }
                }

            case .note:
                swatches($state.noteInk)
                row("Size") {
                    ForEach([9.0, 10.0, 12.0, 14.0, 18.0], id: \.self) { size in
                        choice(text: "\(Int(size))",
                               label: "\(Int(size)) pt",
                               on: state.noteFontSize == size) {
                            state.noteFontSize = size
                        }
                    }
                }

            case .sketch:
                swatches($state.sketchInk)
                weights($state.sketchWidth)
            }

            Divider()
            Toggle("Keep drawing", isOn: $state.sticky)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Off, the tool draws one mark and puts itself away")
        }
        .padding(10)
        .toolPanel()
    }

    // MARK: Parts

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title)
            HStack(spacing: 3) { content() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func swatches(_ ink: Binding<Annotation.Ink>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption("Colour")
            HStack(spacing: 6) {
                ForEach(Annotation.Ink.allCases) { option in
                    let on = ink.wrappedValue == option
                    Button { ink.wrappedValue = option } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 15, height: 15)
                            .overlay {
                                Circle().stroke(.primary.opacity(on ? 0.85 : 0.18),
                                                lineWidth: on ? 2 : 1)
                            }
                            .padding(2)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                }
            }
        }
    }

    private func weights(_ width: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption("Weight")
            HStack(spacing: 3) {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { value in
                    let on = width.wrappedValue == value
                    Button { width.wrappedValue = value } label: {
                        Capsule()
                            .fill(.primary.opacity(on ? 0.9 : 0.45))
                            .frame(width: 16, height: value)
                            .frame(width: 24, height: 20)
                            .contentShape(.rect)
                            .background(on ? Color.accentColor.opacity(0.18) : .clear,
                                        in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("\(Int(value)) pt")
                }
            }
        }
    }

    private func choice(symbol: String? = nil, text: String? = nil,
                        label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                } else {
                    Text(text ?? "").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .frame(width: 24, height: 22)
            .background(on ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Panel chrome and placement

extension View {
    /// What every panel that hangs off the header wears: the tool options and
    /// the model settings alike, so they read as one family of dropdown.
    func toolPanel() -> some View {
        self
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }
}


/// Parks a floating panel under the header button that opened it, kept inside
/// the document's own bounds. Both frames are global; the offset is not, so the
/// panel is measured first and only shown once it knows its own size.
struct UnderAnchor<Content: View>: View {
    let anchor: CGRect
    let container: CGRect
    @ViewBuilder var content: Content

    @State private var size: CGSize?

    var body: some View {
        let panel = size ?? .zero
        let free = max(8, container.width - panel.width - 8)
        let x = min(max(8, anchor.midX - container.minX - panel.width / 2), free)
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: x, y: max(1.5, anchor.maxY - container.minY + 1.5))
            .opacity(size == nil ? 0 : 1)
    }
}
