import Foundation

struct TranscriptHandOff {
    enum Result: Sendable {
        case transcript(String, spans: [TranscriptSpan], warning: String?)
        case failed(String)
        case cancelled
    }

    enum Start {
        case started
        case unavailable(String)
    }

    let id: UUID
    let finish: @MainActor (Result) -> Void
}
