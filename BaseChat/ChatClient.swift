import Foundation

/// Minimal streaming client for BaseRT's OpenAI-compatible `/v1/chat/completions`.
struct ChatClient {
    let baseURL: URL
    let model: String
    let apiKey: String
    let systemPrompt: String
    let temperature: Double
    let topP: Double
    let topK: Int
    let maxTokens: Int
    let frequencyPenalty: Double

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RequestBody: Encodable {
        struct Turn: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Turn]
        let stream: Bool
        let temperature: Double
        let top_p: Double
        let top_k: Int
        let max_tokens: Int
        let frequency_penalty: Double
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    /// Streams assistant text. `onDelta` is called on the main actor for every token.
    func send(_ history: [Message], onDelta: @escaping @MainActor (String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        var turns = history.map { RequestBody.Turn(role: $0.role.rawValue, content: $0.text) }
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            turns.insert(.init(role: "system", content: trimmedSystem), at: 0)
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                messages: turns,
                stream: true,
                temperature: temperature,
                top_p: topP,
                top_k: topK,
                max_tokens: maxTokens,
                frequency_penalty: frequencyPenalty
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw APIError(message: "HTTP \(code): \(body.isEmpty ? "no response body" : body)")
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let text = chunk.choices?.first?.delta?.content, !text.isEmpty
            else { continue }
            await MainActor.run { onDelta(text) }
        }
    }
}
