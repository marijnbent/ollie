import Foundation

enum ShortcutEventType {
    case keyDown
    case keyUp
}

struct ShortcutStateInput {
    let eventType: ShortcutEventType
    let shortcutID: UUID
    let mode: ShortcutMode
    let phase: RecordingPhase
    let ownership: RecordingOwnership?
    let listenedDuration: TimeInterval
}

enum ShortcutAction: Equatable {
    case start(ownerShortcutID: UUID, ownerMode: ShortcutMode, latched: Bool)
    case stop
    case cancel
    case discard
    case scheduleStop
    case setLatched(Bool)
    case noop
}

struct ShortcutStateMachine {
    /// Measured in listened time: a release before half a second of audio can't be push-to-talk.
    static let defaultClickHoldThreshold: TimeInterval = 0.5

    let clickHoldThreshold: TimeInterval

    func reduce(input: ShortcutStateInput) -> [ShortcutAction] {
        guard input.phase != .finalizing else { return [.noop] }

        let isRecording = input.phase == .recording
        if ShortcutOwnershipPolicy.shouldIgnore(
            shortcutID: input.shortcutID,
            isRecording: isRecording,
            ownership: input.ownership
        ) {
            return [.noop]
        }

        switch input.mode {
        case .hold:
            return reduceHold(input: input)
        case .click:
            return reduceClick(input: input)
        case .both:
            return reduceBoth(input: input)
        }
    }

    private func reduceHold(input: ShortcutStateInput) -> [ShortcutAction] {
        switch input.eventType {
        case .keyDown:
            guard input.phase == .idle else { return [.noop] }
            return [.start(ownerShortcutID: input.shortcutID, ownerMode: .hold, latched: false)]
        case .keyUp:
            guard input.phase == .recording,
                  ShortcutOwnershipPolicy.isOwner(shortcutID: input.shortcutID, ownership: input.ownership) else {
                return [.noop]
            }

            if input.listenedDuration < clickHoldThreshold {
                return [.cancel]
            }
            return [.scheduleStop]
        }
    }

    private func reduceClick(input: ShortcutStateInput) -> [ShortcutAction] {
        switch input.eventType {
        case .keyDown:
            if input.phase == .recording {
                guard ShortcutOwnershipPolicy.isOwner(shortcutID: input.shortcutID, ownership: input.ownership) else {
                    return [.noop]
                }
                return [.stop]
            }

            guard input.phase == .idle else { return [.noop] }
            return [.start(ownerShortcutID: input.shortcutID, ownerMode: .click, latched: true)]
        case .keyUp:
            return [.noop]
        }
    }

    private func reduceBoth(input: ShortcutStateInput) -> [ShortcutAction] {
        switch input.eventType {
        case .keyDown:
            if input.phase == .recording {
                guard let ownership = input.ownership,
                      ownership.ownerShortcutID == input.shortcutID,
                      ownership.isLatched else {
                    return [.noop]
                }
                return [.setLatched(false), .stop]
            }

            guard input.phase == .idle else { return [.noop] }
            return [.start(ownerShortcutID: input.shortcutID, ownerMode: .both, latched: false)]

        case .keyUp:
            guard input.phase == .recording,
                  let ownership = input.ownership,
                  ownership.ownerShortcutID == input.shortcutID,
                  !ownership.isLatched else {
                return [.noop]
            }

            if input.listenedDuration < clickHoldThreshold {
                return [.setLatched(true)]
            }
            return [.scheduleStop]
        }
    }
}
