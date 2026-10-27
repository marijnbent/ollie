import AVFoundation
import AppKit
import ApplicationServices
import Foundation

final class ManualClock: ClockPort {
    var currentTime: TimeInterval = 0

    func now() -> TimeInterval {
        currentTime
    }
}

final class ManualScheduledTask: CancellableTask {
    fileprivate var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

final class ManualScheduler: SchedulerPort {
    private struct Entry {
        let deadline: TimeInterval
        let block: () -> Void
        let token: ManualScheduledTask
    }

    private let clock: ManualClock
    private var entries: [Entry] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancellableTask {
        let token = ManualScheduledTask()
        let entry = Entry(deadline: clock.currentTime + delay, block: block, token: token)
        entries.append(entry)
        entries.sort { $0.deadline < $1.deadline }
        return token
    }

    func advance(by delta: TimeInterval) {
        clock.currentTime += delta
        runDueTasks()
    }

    func runAllDueTasks() {
        runDueTasks()
    }

    private func runDueTasks() {
        while true {
            entries.sort { $0.deadline < $1.deadline }
            guard let next = entries.first, next.deadline <= clock.currentTime else { return }

            entries.removeFirst()
            if !next.token.isCancelled {
                next.block()
            }
        }
    }
}

final class FakeAudioCapturePort: AudioCapturePort, @unchecked Sendable {
    enum TestError: Error {
        case startFailed
    }

    var onAudioChunk: (@Sendable (UUID, Linear16AudioChunk) -> Void)?
    var onConfigurationChanged: (@Sendable (UUID) -> Void)?
    var startCallCount = 0
    var stopCallCount = 0
    var startFormat = AudioStreamFormat(sampleRate: 16_000, channels: 1)
    var shouldFailStart = false
    var suspendStart = false
    var startedSessionIDs: [UUID] = []
    var stoppedSessionIDs: [UUID] = []
    private var startContinuation: CheckedContinuation<AudioStreamFormat, Error>?

    func start(sessionID: UUID) async throws -> AudioStreamFormat {
        startCallCount += 1
        startedSessionIDs.append(sessionID)
        if shouldFailStart {
            throw TestError.startFailed
        }
        if suspendStart {
            return try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
            }
        }
        return startFormat
    }

    func stop(sessionID: UUID) async {
        stopCallCount += 1
        stoppedSessionIDs.append(sessionID)
    }

    var hasPendingStart: Bool {
        startContinuation != nil
    }

    func completeStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: startFormat)
    }

    func emit(_ chunk: Linear16AudioChunk, sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? startedSessionIDs.last else { return }
        onAudioChunk?(sessionID, chunk)
    }

    func emitConfigurationChange(sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? startedSessionIDs.last else { return }
        onConfigurationChanged?(sessionID)
    }
}

final class FakeTranscriptionStreamPort: TranscriptionStreamPort {
    struct ConnectCall {
        let provider: TranscriptionProvider
        let includeTimings: Bool
        let apiKey: String
        let format: AudioStreamFormat
        let language: DeepgramLanguage
    }

    var onTranscriptEvent: ((String, Bool) -> Void)?
    var onTimedTranscript: (([TranscriptSpan]) -> Void)?
    var onLog: ((String, LogLevel) -> Void)?
    var onTranscriptionError: ((String) -> Void)?
    var onConnectionDropped: ((String) -> Void)?

    var connectCalls: [ConnectCall] = []
    var sentAudio: [Data] = []
    var disconnectCallCount = 0
    var closeStreamCallCount = 0
    var closeCallbacks: [() -> Void] = []

    func connect(
        settings: TranscriptionProviderSettings,
        format: AudioStreamFormat,
        language: DeepgramLanguage
    ) {
        connectCalls.append(
            ConnectCall(
                provider: settings.provider,
                includeTimings: settings.includeTimings,
                apiKey: settings.apiKey,
                format: format,
                language: language
            )
        )
    }

    func sendAudio(data: Data) {
        sentAudio.append(data)
    }

    func closeStream(onClosed: @escaping () -> Void) {
        closeStreamCallCount += 1
        closeCallbacks.append(onClosed)
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func emitConnectionDropped(_ reason: String) {
        onConnectionDropped?(reason)
    }

    func emitTranscript(_ text: String, isFinal: Bool) {
        onTranscriptEvent?(text, isFinal)
    }

    func emitTranscriptionError(_ message: String) {
        onTranscriptionError?(message)
    }

    func completeClose(index: Int = 0) {
        guard closeCallbacks.indices.contains(index) else { return }
        let cb = closeCallbacks[index]
        cb()
    }
}

final class FakeRawRecordingCapture: RawRecordingCapture, @unchecked Sendable {
    var appendedAudio: [Data] = []
    var discarded = false
    var finishCallCount = 0
    var finishResult: URL?
    var finishError: Error?

    func append(data: Data) {
        appendedAudio.append(data)
    }

    func finish() async throws -> URL? {
        finishCallCount += 1
        if let finishError {
            throw finishError
        }
        return finishResult
    }

    func discard() {
        discarded = true
    }
}

final class FakeSoundPort: SoundPort {
    var playedNames: [String] = []

    func play(named: String) {
        playedNames.append(named)
    }
}

final class FakePasteboardPort: PasteboardPort {
    var changeToken = 0
    var currentSnapshot = PasteboardSnapshotPayload(items: [])
    var writtenStrings: [String] = []
    var restoredSnapshots: [PasteboardSnapshotPayload] = []
    var sendPasteCommandResult = true
    var sendPasteCommandCallCount = 0
    var snapshotCallCount = 0
    var onWriteString: ((String) -> Void)?
    var onSendPasteCommand: (() -> Void)?

    func snapshot() -> PasteboardSnapshotPayload {
        snapshotCallCount += 1
        return currentSnapshot
    }

    func writeString(_ value: String) {
        changeToken += 1
        writtenStrings.append(value)
        onWriteString?(value)
    }

    func restore(_ snapshot: PasteboardSnapshotPayload) {
        restoredSnapshots.append(snapshot)
    }

    func sendPasteCommand() -> Bool {
        sendPasteCommandCallCount += 1
        onSendPasteCommand?()
        return sendPasteCommandResult
    }
}

final class FakePasteVerificationPort: PasteVerificationPort {
    var prepareCallCount = 0
    var checkCallCount = 0
    var prepareResult: PreparedPasteVerification?
    var checkResults: [PasteVerificationCheck] = []
    var onPrepare: ((String) -> Void)?

    func prepare(expectedText: String) -> PreparedPasteVerification? {
        prepareCallCount += 1
        onPrepare?(expectedText)
        return prepareResult
    }

    func check(_ verification: PreparedPasteVerification) -> PasteVerificationCheck {
        checkCallCount += 1
        if !checkResults.isEmpty {
            return checkResults.removeFirst()
        }
        return .pending
    }
}

final class FakeEventMonitorPort: EventMonitorPort {
    var keyDownInterceptor: ((CGKeyCode) -> Bool)?
    var keyboardMonitor: ((KeyboardMonitorEvent) -> Void)?

    func addKeyDownInterceptor(handler: @escaping (CGKeyCode) -> Bool) -> Any? {
        keyDownInterceptor = handler
        return "keyDownInterceptor"
    }

    func addKeyboardMonitor(handler: @escaping (KeyboardMonitorEvent) -> Void) -> Any? {
        keyboardMonitor = handler
        return "keyboardMonitor"
    }

    func removeMonitor(_ monitor: Any) {
        switch monitor as? String {
        case "keyDownInterceptor":
            keyDownInterceptor = nil
        case "keyboardMonitor":
            keyboardMonitor = nil
        default:
            break
        }
    }

    @discardableResult
    func sendKeyDown(_ keyCode: CGKeyCode) -> Bool {
        keyboardMonitor?(.keyDown(keyCode: keyCode))
        return keyDownInterceptor?(keyCode) ?? false
    }

    func sendFlagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        keyboardMonitor?(.flagsChanged(keyCode: CGKeyCode(keyCode), modifiers: modifiers))
    }
}

func makePreparedPasteVerification(
    expectedText: String = "hello world",
    expectedValue: String? = nil,
    expectedSelectedRange: NSRange? = nil,
    initialValue: String = "",
    initialSelectedRange: NSRange = NSRange(location: 0, length: 0)
) -> PreparedPasteVerification {
    let expectedValue = expectedValue ?? expectedText
    let expectedSelectedRange = expectedSelectedRange ?? NSRange(
        location: (expectedText as NSString).length,
        length: 0
    )

    return PreparedPasteVerification(
        expectedText: expectedText,
        expectedValue: expectedValue,
        expectedSelectedRange: expectedSelectedRange,
        focusedElement: AXUIElementCreateSystemWide(),
        initialValue: initialValue,
        initialSelectedRange: initialSelectedRange
    )
}
