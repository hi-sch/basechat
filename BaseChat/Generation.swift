import Foundation

/// Stats handed back after a completion so the UI can label the turn.
struct CompletionInfo: Sendable {
    var tokensPerSecond: Double?
    var trimmed: Bool
    var memoryBytes: Int?
}

/// Splits a token stream into a hidden reasoning fold and the visible answer.
///
/// Handles `<think>…</think>` (Qwen and friends) and an Edge0-style
/// `thinking` / `response` split. Until a marker is seen, text is held briefly
/// so a tag that arrives across two tokens is not flashed as the answer.
final class ThinkSplitter {
    private enum Phase { case unknown, reasoning, answer }
    private var phase: Phase = .unknown
    private var hold = ""

    func push(_ chunk: String) -> (reasoning: String, answer: String) {
        hold += chunk
        switch phase {
        case .unknown:
            if let range = hold.range(of: "<think>", options: .caseInsensitive)
                ?? hold.range(of: "<think ", options: .caseInsensitive) {
                phase = .reasoning
                let before = String(hold[..<range.lowerBound])
                var rest = String(hold[range.upperBound...])
                if hold[range].hasSuffix(" "),
                   let close = rest.firstIndex(of: ">") {
                    rest = String(rest[rest.index(after: close)...])
                }
                hold = rest
                let (r, a) = drainReasoning()
                return (r, before + a)
            }
            // Give a tag a chance to complete; after that, treat it as the answer.
            if hold.count > 24, !hold.lowercased().hasPrefix("<thi") {
                phase = .answer
                let out = hold
                hold = ""
                return ("", out)
            }
            return ("", "")
        case .reasoning:
            return drainReasoning()
        case .answer:
            let out = hold
            hold = ""
            return ("", out)
        }
    }

    func finish() -> (reasoning: String, answer: String) {
        switch phase {
        case .unknown, .answer:
            let out = hold
            hold = ""
            return ("", out)
        case .reasoning:
            // Edge0: reasoning then a "response" marker, no </think>.
            if let range = hold.range(of: "\nresponse", options: .caseInsensitive)
                ?? hold.range(of: "response\n", options: .caseInsensitive) {
                let r = String(hold[..<range.lowerBound])
                let a = String(hold[range.upperBound...])
                hold = ""
                return (r, a)
            }
            // Qwen3 often never emits </think>. Treat the body as the answer
            // so the UI is not left on "Thinking" + "No response."
            // Leave unclosed `<think>` in the reasoning fold so the visible
            // answer stays the formatted reply after `</think>`.
            let leftover = hold
            hold = ""
            return (leftover, "")
        }
    }

    private func drainReasoning() -> (reasoning: String, answer: String) {
        if let range = hold.range(of: "</think>", options: .caseInsensitive) {
            let r = String(hold[..<range.lowerBound])
            hold = String(hold[range.upperBound...])
            phase = .answer
            let a = hold
            hold = ""
            return (r, a)
        }
        let r = hold
        hold = ""
        return (r, "")
    }
}

/// Drops oldest turns from the middle so the prompt stays inside a budget.
enum HistoryTrim {
    /// Rough character budget for the prompt. `maxTokens` is the *reply* cap;
    /// history is allowed several times that, with a floor so short settings
    /// still keep a usable conversation.
    static func budget(maxTokens: Int) -> Int {
        max(maxTokens * 6, 12_000)
    }

    static func apply(_ history: [Message], maxTokens: Int) -> (messages: [Message], trimmed: Bool) {
        let live = history.filter { !$0.text.isEmpty || $0.role == .user }
        let limit = budget(maxTokens: maxTokens)
        let total = live.reduce(0) { $0 + $1.text.count }
        guard total > limit, live.count > 2 else { return (live, false) }

        var kept = live
        // Always keep the last user turn (and a trailing empty assistant stub
        // is already filtered). Drop the oldest non-final pair until it fits.
        while kept.count > 2 {
            let size = kept.reduce(0) { $0 + $1.text.count }
            if size <= limit { break }
            kept.remove(at: 0)
        }
        return (kept, kept.count != live.count)
    }
}
