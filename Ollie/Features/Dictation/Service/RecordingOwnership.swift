import Foundation

struct RecordingOwnership {
    let ownerShortcutID: UUID
    let ownerMode: ShortcutMode
    var isLatched: Bool
    var listeningStartedAt: TimeInterval?
    let sessionID: UUID
}
