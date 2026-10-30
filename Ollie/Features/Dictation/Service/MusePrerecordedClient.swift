import Foundation

enum MusePrerecordedClient {
    static let endpoint = URL(string: "https://api.meta.ai/v1/asr/transcribe")!
    static let model = "muse-voice-transcribe-1.0"

    static func transcribe(
        fileURL: URL,
        apiKey: String,
        language: DeepgramLanguage,
        automaticLanguageCandidates: [DeepgramLanguage]
    ) async throws -> String {
        let session = DictationHTTP.session()
        defer { session.invalidateAndCancel() }
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: fileURL)
        } catch {
            throw MusePrerecordedError.requestFailed(reason: error.localizedDescription)
        }

        let wavData = try normalizedWAV(sourceData)
        let boundary = "Talkie-Muse-\(UUID().uuidString)"
        let body = try makeMultipartBody(
            wavData: wavData,
            language: language,
            automaticLanguageCandidates: automaticLanguageCandidates,
            boundary: boundary
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.upload(for: request, from: body)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MusePrerecordedError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw MusePrerecordedError.httpError(
                    statusCode: httpResponse.statusCode,
                    body: preview(String(data: data, encoding: .utf8) ?? "")
                )
            }

            let decoded: MusePrerecordedResponse
            do {
                decoded = try JSONDecoder().decode(MusePrerecordedResponse.self, from: data)
            } catch {
                throw MusePrerecordedError.invalidResponse
            }
            guard !decoded.transcript.trimmed.isEmpty else {
                throw MusePrerecordedError.noTranscript
            }
            return decoded.transcript.trimmed
        } catch let error as MusePrerecordedError {
            throw error
        } catch let error as URLError {
            throw MusePrerecordedError.requestFailed(reason: error.localizedDescription)
        }
    }

    static func makeMultipartBody(
        wavData: Data,
        language: DeepgramLanguage,
        automaticLanguageCandidates: [DeepgramLanguage] = TranscriptionProvider.muse.defaultAutomaticLanguageCandidates,
        boundary: String
    ) throws -> Data {
        let settings = MuseTranscribeSettings(
            mode: "PUSH_TO_TALK",
            model: model,
            audioEncoding: "WAV",
            languageBias: language == .automatic
                ? TranscriptionProvider.muse
                    .normalizedAutomaticLanguageCandidates(automaticLanguageCandidates)
                    .compactMap(\.museLanguageName)
                : language.museLanguageName.map { [$0] } ?? []
        )
        let settingsData = try JSONEncoder().encode(settings)

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"request\"\r\n".utf8))
        body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        body.append(settingsData)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func normalizedWAV(_ data: Data) throws -> Data {
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw MusePrerecordedError.unsupportedRecording
        }
        var format: Range<Int>?
        var audio: Range<Int>?
        var offset = 12
        while offset <= data.count - 8 {
            let size = Int(readUInt32(data, at: offset + 4))
            let start = offset + 8
            guard size <= data.count - start else { throw MusePrerecordedError.unsupportedRecording }
            let chunk = start..<(start + size)
            switch String(bytes: data[offset..<(offset + 4)], encoding: .ascii) {
            case "fmt ": format = chunk
            case "data": audio = chunk
            default: break
            }
            offset = chunk.upperBound + size % 2
        }
        guard let format, format.count >= 16,
              let audio, !audio.isEmpty,
              readUInt16(data, at: format.lowerBound + 14) == 16 else {
            throw MusePrerecordedError.unsupportedRecording
        }
        let encoding = readUInt16(data, at: format.lowerBound)
        let isExtendedPCM = encoding == 0xfffe && format.count >= 40
            && readUInt32(data, at: format.lowerBound + 24) == 1
        guard encoding == 1 || isExtendedPCM else { throw MusePrerecordedError.unsupportedRecording }
        let channels = Int(readUInt16(data, at: format.lowerBound + 2))
        let sampleRate = Int(readUInt32(data, at: format.lowerBound + 4))
        guard channels > 0, sampleRate > 0 else { throw MusePrerecordedError.unsupportedRecording }

        let converter = MusePCMConverter(
            format: AudioStreamFormat(sampleRate: sampleRate, channels: channels)
        )
        var pcmData = converter.convert(Data(data[audio]))
        pcmData.append(converter.finish())
        guard !pcmData.isEmpty else {
            throw MusePrerecordedError.unsupportedRecording
        }
        return makeWAV(pcmData: pcmData, sampleRate: converter.sampleRate)
    }

    private static func makeWAV(pcmData: Data, sampleRate: Int) -> Data {
        let byteCount = UInt32(pcmData.count)
        let sampleRate = UInt32(sampleRate)
        var data = Data()
        data.reserveCapacity(44 + pcmData.count)
        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + byteCount)
        data.append(Data("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(Data("data".utf8))
        data.appendLittleEndian(byteCount)
        data.append(pcmData)
        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func preview(_ text: String, maxLength: Int = 400) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "…"
    }
}

enum MusePrerecordedError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case noTranscript
    case requestFailed(reason: String)
    case unsupportedRecording

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Muse."
        case .httpError(let statusCode, let body):
            return "Muse HTTP \(statusCode): \(body)"
        case .noTranscript:
            return "Muse returned no transcript."
        case .requestFailed(let reason):
            return "Muse request failed: \(reason)"
        case .unsupportedRecording:
            return "Muse requires a valid 16-bit PCM WAV recording."
        }
    }
}

private struct MuseTranscribeSettings: Encodable {
    let mode: String
    let model: String
    let audioEncoding: String
    let languageBias: [String]?
}

private struct MusePrerecordedResponse: Decodable {
    let transcript: String
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
