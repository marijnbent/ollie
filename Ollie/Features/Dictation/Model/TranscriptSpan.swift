import Foundation

struct TranscriptSpan: Codable, Hashable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var isValid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end >= start
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func shifted(by offset: TimeInterval) -> Self {
        Self(text: text, start: start + offset, end: end + offset)
    }
}
