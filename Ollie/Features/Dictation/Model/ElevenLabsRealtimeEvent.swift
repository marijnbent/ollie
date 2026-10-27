import Foundation

struct ElevenLabsRealtimeEvent: Decodable, Equatable {
    let messageType: String?
    let text: String?
    let error: String?
    let sessionID: String?
    let words: [Word]?

    struct Word: Decodable, Equatable {
        let text: String?
        let start: Double?
        let end: Double?

        var span: TranscriptSpan? {
            guard let text, let start, let end else { return nil }
            let span = TranscriptSpan(text: text, start: start, end: end)
            return span.isValid ? span : nil
        }
    }

    var spans: [TranscriptSpan] { words?.compactMap(\.span) ?? [] }

    func completesCommit(includingTimings: Bool) -> Bool {
        messageType == "committed_transcript_with_timestamps"
            || !includingTimings && messageType == "committed_transcript"
    }

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
        case error
        case sessionID = "session_id"
        case words
    }
}
