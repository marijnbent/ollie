import AppKit
import Foundation

@MainActor
final class ShortcutRuntime {
    private struct MonitoredShortcut {
        let id: UUID
        let hotkey: Hotkey
        let mode: ShortcutMode
    }

    private struct PendingShortcutGesture {
        let shortcutID: UUID
        let keyCode: CGKeyCode
    }

    private let eventMonitor: EventMonitorPort
    private let clock: ClockPort
    private let stateMachine: ShortcutStateMachine

    private var shortcuts: [MonitoredShortcut] = []
    private var keyboardMonitor: Any?
    private var pendingShortcutGesture: PendingShortcutGesture?
    private var isSuperCapsLockPressed = false
    private var isCyclingLanguageWithSuperCapsLock = false

    private let superCapsLockModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var phaseProvider: (() -> RecordingPhase)?
    var ownershipProvider: (() -> RecordingOwnership?)?
    var onActions: (([ShortcutAction]) -> Void)?
    var onCycleLanguage: (() -> Void)?

    init(
        eventMonitor: EventMonitorPort,
        clock: ClockPort,
        clickHoldThreshold: TimeInterval
    ) {
        self.eventMonitor = eventMonitor
        self.clock = clock
        self.stateMachine = ShortcutStateMachine(clickHoldThreshold: clickHoldThreshold)
    }

    func configure(shortcuts: [ShortcutConfig]) {
        self.shortcuts = shortcuts.map {
            MonitoredShortcut(id: $0.id, hotkey: Hotkey(shortcutKey: $0.key), mode: $0.mode)
        }
        pendingShortcutGesture = nil
    }

    func start() {
        stop()

        keyboardMonitor = eventMonitor.addKeyboardMonitor { [weak self] event in
            self?.handleKeyboardEvent(event)
        }
    }

    func recoverMonitor() {
        if let keyboardMonitor, eventMonitor.isHealthy(keyboardMonitor) { return }
        start()
    }

    func stop() {
        if let monitor = keyboardMonitor {
            eventMonitor.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        pendingShortcutGesture = nil
        isSuperCapsLockPressed = false
        isCyclingLanguageWithSuperCapsLock = false
    }

    private func handleKeyboardEvent(_ event: KeyboardMonitorEvent) {
        switch event {
        case .flagsChanged(let keyCode, let modifiers):
            handleShortcutFlagsChanged(keyCode: UInt16(keyCode), modifiers: modifiers)
        case .keyDown(let keyCode):
            handleCompanionKeyDown(keyCode: keyCode)
        }
    }

    private func handleShortcutFlagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let normalizedModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        let wasSuperCapsLockPressed = isSuperCapsLockPressed
        isSuperCapsLockPressed = normalizedModifiers.contains(superCapsLockModifiers)

        if !wasSuperCapsLockPressed,
           isSuperCapsLockPressed,
           phaseProvider?() == .recording {
            isCyclingLanguageWithSuperCapsLock = true
            onCycleLanguage?()
            return
        }

        if isCyclingLanguageWithSuperCapsLock {
            if !isSuperCapsLockPressed {
                isCyclingLanguageWithSuperCapsLock = false
            }
            return
        }

        for shortcut in shortcuts where shortcut.hotkey.keyCode == keyCode {
            let eventType: ShortcutEventType = normalizedModifiers.contains(shortcut.hotkey.modifiers)
                ? .keyDown
                : .keyUp
            dispatch(
                eventType: eventType,
                shortcutID: shortcut.id,
                shortcutKeyCode: CGKeyCode(shortcut.hotkey.keyCode),
                mode: shortcut.mode
            )
        }
    }

    private func dispatch(
        eventType: ShortcutEventType,
        shortcutID: UUID,
        shortcutKeyCode: CGKeyCode,
        mode: ShortcutMode
    ) {
        if eventType == .keyUp, pendingShortcutGesture?.shortcutID == shortcutID {
            pendingShortcutGesture = nil
        }

        let phase = phaseProvider?() ?? .idle
        let ownership = ownershipProvider?()

        let listenedDuration: TimeInterval
        if let ownership, ownership.ownerShortcutID == shortcutID,
           let listeningStartedAt = ownership.listeningStartedAt {
            listenedDuration = max(0, clock.now() - listeningStartedAt)
        } else {
            listenedDuration = 0
        }

        let actions = stateMachine.reduce(
            input: ShortcutStateInput(
                eventType: eventType,
                shortcutID: shortcutID,
                mode: mode,
                phase: phase,
                ownership: ownership,
                listenedDuration: listenedDuration
            )
        )

        guard actions != [.noop] else { return }
        onActions?(actions)

        if case .start = actions.first {
            pendingShortcutGesture = PendingShortcutGesture(
                shortcutID: shortcutID,
                keyCode: shortcutKeyCode
            )
        }
    }

    private func handleCompanionKeyDown(keyCode: CGKeyCode) {
        guard let pendingShortcutGesture,
              keyCode != pendingShortcutGesture.keyCode else { return }

        guard phaseProvider?() == .recording,
              ownershipProvider?()?.ownerShortcutID == pendingShortcutGesture.shortcutID else {
            self.pendingShortcutGesture = nil
            return
        }

        self.pendingShortcutGesture = nil
        onActions?([.discard])
    }
}
