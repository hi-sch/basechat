import Foundation

// MARK: - Chat data

struct Message: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user, assistant
    }

    var id = UUID()
    var role: Role
    var text: String
}

struct Chat: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = "New Chat"
    var created = Date()
    /// Optional so chats written before this field still decode.
    var updated: Date?
    var messages: [Message] = []

    var lastActivity: Date { updated ?? created }

    var subtitle: String {
        messages.last?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages"
    }

    /// Notes-style: time for today, weekday this week, otherwise a short date.
    var dateLabel: String {
        let date = lastActivity
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "dd/MM/yy"
        }
        return formatter.string(from: date)
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
