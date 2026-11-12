import AppKit
import Foundation
import Carbon

@MainActor
final class ShortcutRuntimeTests {
    private let superCapsLockModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
    ]

    func testSuperCapsLockCyclesOncePerPressOnlyWhileRecording() {
        let eventMonitor = FakeEventMonitorPort()
        let runtime = ShortcutRuntime(
            eventMonitor: eventMonitor,
            clock: ManualClock(),
            clickHoldThreshold: 0.2
        )
        var phase = RecordingPhase.idle
        var cycleCount = 0
        runtime.phaseProvider = { phase }
        runtime.onCycleLanguage = { cycleCount += 1 }
        runtime.start()

        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: superCapsLockModifiers
        )
        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: []
        )
        assertEqual(cycleCount, 0)

        phase = .recording
        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: superCapsLockModifiers
        )
        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Command),
            modifiers: superCapsLockModifiers
        )
        assertEqual(cycleCount, 1)

        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: []
        )
        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: superCapsLockModifiers
        )
        assertEqual(cycleCount, 2)

        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: []
        )
        phase = .finalizing
        eventMonitor.sendFlagsChanged(
            keyCode: UInt16(kVK_Shift),
            modifiers: superCapsLockModifiers
        )
        assertEqual(cycleCount, 2)
    }

    func testCompanionKeyDiscardsRecordingWhileShortcutIsHeldWithoutConsumingKey() {
        let harness = makeCompanionKeyHarness()

        harness.eventMonitor.sendFlagsChanged(
            keyCode: harness.shortcut.key.keyCode,
            modifiers: harness.shortcut.key.modifierFlag
        )
        harness.clock.currentTime = 1
        let wasConsumed = harness.eventMonitor.sendKeyDown(CGKeyCode(kVK_ANSI_Slash))

        assertFalse(wasConsumed)
        assertEqual(harness.receivedActions.value.last, .discard)
    }

    func testFnKeyDownDoesNotDiscardItsOwnQuickPress() {
        let harness = makeCompanionKeyHarness(key: .fn)

        harness.eventMonitor.sendFlagsChanged(
            keyCode: harness.shortcut.key.keyCode,
            modifiers: harness.shortcut.key.modifierFlag
        )
        _ = harness.eventMonitor.sendKeyDown(CGKeyCode(harness.shortcut.key.keyCode))
        harness.clock.currentTime = 0.1
        harness.eventMonitor.sendFlagsChanged(
            keyCode: harness.shortcut.key.keyCode,
            modifiers: []
        )

        assertFalse(harness.receivedActions.value.contains(.discard))
        assertTrue(harness.receivedActions.value.contains(.setLatched(true)))
    }

    func testShippedThresholdClassifiesByListenedTime() {
        let threshold = ShortcutStateMachine.defaultClickHoldThreshold
        let beforeCapture = makeCompanionKeyHarness(clickHoldThreshold: threshold)
        beforeCapture.pressShortcut()
        beforeCapture.clock.currentTime = 1.0
        beforeCapture.releaseShortcut()
        assertEqual(beforeCapture.receivedActions.value.last, .setLatched(true))
        assertFalse(beforeCapture.receivedActions.value.contains(.scheduleStop))

        let tap = makeCompanionKeyHarness(clickHoldThreshold: threshold)
        tap.pressShortcut()
        tap.clock.currentTime = 0.7
        tap.startListening()
        tap.clock.currentTime = 1.0
        tap.releaseShortcut()
        assertEqual(tap.receivedActions.value.last, .setLatched(true))
        assertFalse(tap.receivedActions.value.contains(.scheduleStop))

        let hold = makeCompanionKeyHarness(clickHoldThreshold: threshold)
        hold.pressShortcut()
        hold.clock.currentTime = 0.4
        hold.startListening()
        hold.clock.currentTime = 1.2
        hold.releaseShortcut()
        assertEqual(hold.receivedActions.value.last, .scheduleStop)
    }

    private func makeCompanionKeyHarness(
        key: ShortcutKey = .rightOption, clickHoldThreshold: TimeInterval = 0.2
    ) -> CompanionKeyHarness {
        let eventMonitor = FakeEventMonitorPort()
        let clock = ManualClock()
        let shortcut = ShortcutConfig(id: UUID(), key: key, mode: .both)
        let runtime = ShortcutRuntime(
            eventMonitor: eventMonitor,
            clock: clock,
            clickHoldThreshold: clickHoldThreshold
        )
        var phase = RecordingPhase.idle
        let receivedActions = ShortcutActionRecorder()
        runtime.phaseProvider = { phase }
        runtime.ownershipProvider = { receivedActions.ownership }
        runtime.onActions = { actions in
            receivedActions.value.append(contentsOf: actions)
            if case .start = actions.first {
                phase = .recording
                receivedActions.ownership = RecordingOwnership(
                    ownerShortcutID: shortcut.id,
                    ownerMode: shortcut.mode,
                    isLatched: false,
                    listeningStartedAt: nil,
                    sessionID: UUID()
                )
            }
        }
        runtime.configure(shortcuts: [shortcut])
        runtime.start()
        return CompanionKeyHarness(
            runtime: runtime,
            eventMonitor: eventMonitor,
            clock: clock,
            shortcut: shortcut,
            receivedActions: receivedActions
        )
    }
}

private struct CompanionKeyHarness {
    let runtime: ShortcutRuntime
    let eventMonitor: FakeEventMonitorPort
    let clock: ManualClock
    let shortcut: ShortcutConfig
    let receivedActions: ShortcutActionRecorder

    func pressShortcut() {
        eventMonitor.sendFlagsChanged(keyCode: shortcut.key.keyCode, modifiers: shortcut.key.modifierFlag)
    }

    func releaseShortcut() {
        eventMonitor.sendFlagsChanged(keyCode: shortcut.key.keyCode, modifiers: [])
    }

    func startListening() {
        receivedActions.ownership?.listeningStartedAt = clock.now()
    }
}

private final class ShortcutActionRecorder {
    var value: [ShortcutAction] = []
    var ownership: RecordingOwnership?
}
