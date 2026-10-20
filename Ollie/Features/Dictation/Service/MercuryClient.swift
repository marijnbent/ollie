import Foundation

enum MercuryClient {
    static let model = "mercury-3"
    private static let endpoint = URL(string: "https://api.inceptionlabs.ai/v1/chat/completions")!

    static func enhance(transcript: String, prompt: String, apiKey: String, model: String) async throws -> String {
        let session = DictationHTTP.session()
        defer { session.invalidateAndCancel() }
        let request = try makeRequest(transcript: transcript, prompt: prompt, apiKey: apiKey, model: model)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw MercuryError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                throw MercuryError.httpError(response.statusCode)
            }
            return try content(from: data)
        } catch let error as URLError {
            throw MercuryError.requestFailed(error.localizedDescription)
        }
    }

    static func makeRequest(transcript: String, prompt: String, apiKey: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.trimmed,
            "reasoning_effort": "low",
            "messages": [
                ["role": "user", "content": "\(prompt)\n\n<transcription>\(transcript)</transcription>"]
            ]
        ])
        return request
    }

    static func content(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let content = response.choices.first?.message.content, !content.trimmed.isEmpty else {
            throw MercuryError.noContent
        }
        return content
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }
}

enum MercuryError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noContent
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Mercury."
        case .httpError(let status): "Mercury HTTP \(status)."
        case .noContent: "Mercury returned no content."
        case .requestFailed(let reason): "Mercury request failed: \(reason)"
        }
    }
}
