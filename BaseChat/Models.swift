import Foundation

// MARK: - Chat data

struct Message: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user, assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    /// When the turn was created — shown in the row footer.
    var created: Date = Date()
    /// `org/name:variant` of the model that produced this turn. Assistant only,
    /// so switching models mid-chat leaves the old answers labelled with the old id.
    var model: String?

    init(id: UUID = UUID(), role: Role, text: String, created: Date = Date(), model: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.created = created
        self.model = model
    }

    // Hand-written so chats saved before `created`/`model` existed still decode.
    enum CodingKeys: String, CodingKey { case id, role, text, created, model }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try box.decode(Role.self, forKey: .role)
        text = try box.decode(String.self, forKey: .text)
        created = try box.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        model = try box.decodeIfPresent(String.self, forKey: .model)
    }

    /// `2:32 PM`
    var timeLabel: String { Self.clock.string(from: created) }

    // Formatters are expensive to build and these run per turn, per redraw.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// `Qwen3 4B · q4` from `org/qwen3-4b:q4`.
    var modelLabel: String? {
        guard let model else { return nil }
        return Message.prettyModel(model)
    }

    static func prettyModel(_ id: String) -> String {
        let parts = id.split(separator: ":", maxSplits: 1)
        let name = parts[0].split(separator: "/").last.map(String.init) ?? String(parts[0])
        guard parts.count == 2 else { return name }
        return "\(name) · \(parts[1])"
    }
}

// MARK: - Annotations

/// A mark drawn over a page. Geometry is normalized to the page box (0…1) so it
/// survives zoom, window resizing and repagination of everything above it.
struct Annotation: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case highlight, underline, strikethrough, sketch, text, shape
    }

    enum Ink: String, Codable, CaseIterable, Identifiable {
        case yellow, green, blue, pink, purple
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var shade: Shade {
            switch self {
            case .yellow: return Shade(red: 0.98, green: 0.78, blue: 0.20, alpha: 1)
            case .green: return Shade(red: 0.42, green: 0.78, blue: 0.39, alpha: 1)
            case .blue: return Shade(red: 0.33, green: 0.63, blue: 0.94, alpha: 1)
            case .pink: return Shade(red: 0.93, green: 0.35, blue: 0.47, alpha: 1)
            case .purple: return Shade(red: 0.72, green: 0.50, blue: 0.92, alpha: 1)
            }
        }
    }

    /// Any colour, with opacity — what the native colour well hands back.
    struct Shade: Codable, Hashable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        static let clear = Shade(red: 0, green: 0, blue: 0, alpha: 0)
        var isClear: Bool { alpha < 0.005 }
    }

    var id = UUID()
    var kind: Kind
    var ink: Ink = .yellow
    /// Index of the page this mark lives on.
    var page: Int
    /// Normalized bounding box — also the selection and drag handle.
    var rect: CGRect
    /// Per-line boxes for text marks. Preview paints one band per line of the
    /// selection rather than one rectangle around the whole thing.
    var bands: [CGRect] = []
    /// Normalized freehand path, for `.sketch`.
    var points: [CGPoint] = []
    /// Body of a `.text` annotation.
    var text: String = ""
    /// Shape styling. A nil stroke falls back to the preset ink; a clear fill
    /// means outline only.
    var stroke: Shade?
    var fill: Shade?
    var lineWidth: Double = 2
    var cornerRadius: Double = 4
    var fontSize: Double = 12

    /// Colour actually drawn for the outline, falling back to the preset ink.
    var strokeShade: Shade { stroke ?? ink.shade }
    /// Colour actually drawn inside, if any.
    var fillShade: Shade? {
        guard let fill, !fill.isClear else { return nil }
        return fill
    }

    /// Text marks are a selection, not an object: they cannot be dragged or
    /// resized, only recoloured and deleted.
    var isTextMark: Bool {
        kind == .highlight || kind == .underline || kind == .strikethrough
    }

    /// Text marks paint their bands; everything else paints its box.
    var paintedBands: [CGRect] { bands.isEmpty ? [rect] : bands }

    enum CodingKeys: String, CodingKey {
        case id, kind, ink, page, rect, bands, points, text
        case stroke, fill, fillInk, filled, lineWidth, cornerRadius, fontSize
    }

    init(id: UUID = UUID(), kind: Kind, ink: Ink = .yellow, page: Int, rect: CGRect,
         bands: [CGRect] = [], points: [CGPoint] = [], text: String = "",
         stroke: Shade? = nil, fill: Shade? = nil, lineWidth: Double = 2,
         cornerRadius: Double = 4, fontSize: Double = 12) {
        self.id = id
        self.kind = kind
        self.ink = ink
        self.page = page
        self.rect = rect
        self.bands = bands
        self.points = points
        self.text = text
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
    }

    // Lenient, so marks saved before the styling fields existed still decode.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try box.decode(Kind.self, forKey: .kind)
        ink = try box.decodeIfPresent(Ink.self, forKey: .ink) ?? .yellow
        page = try box.decode(Int.self, forKey: .page)
        rect = try box.decode(CGRect.self, forKey: .rect)
        bands = try box.decodeIfPresent([CGRect].self, forKey: .bands) ?? []
        points = try box.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
        stroke = try box.decodeIfPresent(Shade.self, forKey: .stroke)
        // The fill has had three shapes: a free colour, a preset ink before
        // that, and a plain flag before that.
        if let shade = ((try? box.decodeIfPresent(Shade.self, forKey: .fill)) ?? nil) {
            fill = shade
        } else if let preset = ((try? box.decodeIfPresent(Ink.self, forKey: .fill)) ?? nil) {
            fill = preset.shade
        } else if ((try? box.decodeIfPresent(Bool.self, forKey: .filled)) ?? nil) == true {
            fill = ink.shade
        } else {
            fill = nil
        }
        lineWidth = try box.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 2
        cornerRadius = try box.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 4
        fontSize = try box.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(kind, forKey: .kind)
        try box.encode(ink, forKey: .ink)
        try box.encode(page, forKey: .page)
        try box.encode(rect, forKey: .rect)
        try box.encode(bands, forKey: .bands)
        try box.encode(points, forKey: .points)
        try box.encode(text, forKey: .text)
        try box.encodeIfPresent(stroke, forKey: .stroke)
        try box.encodeIfPresent(fill, forKey: .fill)
        try box.encode(lineWidth, forKey: .lineWidth)
        try box.encode(cornerRadius, forKey: .cornerRadius)
        try box.encode(fontSize, forKey: .fontSize)
    }
}

// MARK: - Chat

struct Chat: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = "New Chat"
    var created = Date()
    /// Optional so chats written before this field still decode.
    var updated: Date?
    var messages: [Message] = []
    /// Highlights, notes and sketches drawn over the paginated transcript.
    var annotations: [Annotation] = []

    var lastActivity: Date { updated ?? created }

    var subtitle: String {
        guard let text = messages.last?.text else { return "No messages" }
        // One line in a sidebar row; flattening a whole streamed answer to
        // build it would be work thrown away on every token.
        return String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }

    /// Notes-style: time for today, weekday this week, otherwise a short date.
    var dateLabel: String {
        let date = lastActivity
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return Self.timeOfDay.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            return Self.weekday.string(from: date)
        }
        return Self.shortDate.string(from: date)
    }

    private static let timeOfDay = Chat.formatter("HH:mm")
    private static let weekday = Chat.formatter("EEEE")
    private static let shortDate = Chat.formatter("dd/MM/yy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }

    /// The whole conversation as Markdown, for the copy button.
    var transcript: String {
        var lines = ["# \(title)", ""]
        for message in messages where !message.text.isEmpty {
            lines.append(message.role == .user ? "**You:**" : "**Assistant:**")
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - BaseRT model catalog

/// One row of `basert list [--remote] --json`.
struct ModelInfo: Codable, Identifiable, Hashable {
    var modelID: String
    var variant: String
    var arch: String?
    var quant: String?
    var sizeBytes: Int64?
    var installed: Bool
    var sourceKind: String?
    /// Absolute path of the `.base` file (present for installed models).
    var path: String?

    /// `org/name:variant` — what `basert serve` and the API expect.
    var id: String { "\(modelID):\(variant)" }

    var displayName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    var sizeText: String {
        guard let bytes = sizeBytes, bytes > 0 else { return "—" }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case variant
        case arch
        case quant
        case sizeBytes = "size_bytes"
        case installed
        case sourceKind = "source_kind"
        case path
    }
}
