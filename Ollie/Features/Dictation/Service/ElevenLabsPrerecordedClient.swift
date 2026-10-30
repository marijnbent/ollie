import Foundation

enum ElevenLabsPrerecordedClient {
    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    static let model = "scribe_v2"
    static let maxAttempts = 3
    static let retryDelayNanoseconds: UInt64 = 200_000_000

    static func transcribe(fileURL: URL, apiKey: String, language: DeepgramLanguage) async throws -> String {
        let session = DictationHTTP.session()
        defer { session.invalidateAndCancel() }
        let boundary = "Talkie-ElevenLabs-\(UUID().uuidString)"
        let body = try makeMultipartFile(fileURL: fileURL, language: language, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.upload(for: request, fromFile: body)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ElevenLabsPrerecordedError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    let error = ElevenLabsPrerecordedError.httpError(
                        statusCode: httpResponse.statusCode,
                        body: preview(String(data: data, encoding: .utf8) ?? "")
                    )
                    guard attempt < maxAttempts, shouldRetry(statusCode: httpResponse.statusCode) else {
                        throw error
                    }
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds * UInt64(attempt))
                    continue
                }

                let decoded = try decodeResponse(data)
                guard !decoded.text.trimmed.isEmpty else {
                    throw ElevenLabsPrerecordedError.noTranscript
                }
                return decoded.text.trimmed
            } catch let error as ElevenLabsPrerecordedError {
                throw error
            } catch let error as DecodingError {
                throw ElevenLabsPrerecordedError.invalidResponseDetails(error.localizedDescription)
            } catch let error as URLError {
                guard attempt < maxAttempts, shouldRetry(error: error) else {
                    throw ElevenLabsPrerecordedError.requestFailed(reason: error.localizedDescription)
                }
                try await Task.sleep(nanoseconds: retryDelayNanoseconds * UInt64(attempt))
            }
        }
    }

    static func makeMultipartFile(
        fileURL: URL,
        language: DeepgramLanguage,
        boundary: String
    ) throws -> URL {
        var body = Data()
        appendField("model_id", value: model, to: &body, boundary: boundary)
        if let languageCode = elevenLabsLanguageCode(for: language) {
            appendField("language_code", value: languageCode, to: &body, boundary: boundary)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        let fileName = escapedFileName(fileURL.lastPathComponent)
        let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
        body.append(Data(disposition.utf8))
        body.append(Data("Content-Type: \(contentType(for: fileURL))\r\n\r\n".utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try output.write(contentsOf: body)
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func decodeResponse(_ data: Data) throws -> ElevenLabsPrerecordedResponse {
        try JSONDecoder().decode(ElevenLabsPrerecordedResponse.self, from: data)
    }

    private static func appendField(_ name: String, value: String, to body: inout Data, boundary: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    private static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    private static func escapedFileName(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func shouldRetry(error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func preview(_ text: String, maxLength: Int = 400) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "…"
    }
}

enum ElevenLabsPrerecordedError: LocalizedError {
    case invalidResponse
    case invalidResponseDetails(String)
    case httpError(statusCode: Int, body: String)
    case noTranscript
    case requestFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from ElevenLabs."
        case .invalidResponseDetails(let reason):
            return "Invalid response from ElevenLabs: \(reason)"
        case .httpError(let statusCode, let body):
            return "ElevenLabs HTTP \(statusCode): \(body)"
        case .noTranscript:
            return "ElevenLabs returned no transcript."
        case .requestFailed(let reason):
            return "ElevenLabs request failed: \(reason)"
        }
    }
}

struct ElevenLabsPrerecordedResponse: Decodable, Equatable {
    let languageCode: String?
    let languageProbability: Double?
    let text: String
    let words: [ElevenLabsWord]?

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case languageProbability = "language_probability"
        case text
        case words
    }
}

struct ElevenLabsWord: Decodable, Equatable {
    let end: Double?
    let start: Double?
    let text: String?
    let type: String?
    let speakerID: String?

    enum CodingKeys: String, CodingKey {
        case end
        case start
        case text
        case type
        case speakerID = "speaker_id"
    }
}
