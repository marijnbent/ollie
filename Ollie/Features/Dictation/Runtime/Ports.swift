import AppKit
import ApplicationServices
import AVFoundation
import Foundation

@MainActor
protocol CancellableTask {
    func cancel()
}

@MainActor
protocol SchedulerPort {
    @discardableResult
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> CancellableTask
}

protocol ClockPort {
    func now() -> TimeInterval
}

protocol AudioCapturePort: AnyObject, Sendable {
    var onAudioChunk: (@Sendable (UUID, Linear16AudioChunk) -> Void)? { get set }
    var onConfigurationChanged: (@Sendable (UUID) -> Void)? { get set }
    func start(sessionID: UUID) async throws -> AudioStreamFormat
    func stop(sessionID: UUID) async
}

protocol TranscriptionStreamPort: AnyObject {
    var onTranscriptEvent: ((String, Bool) -> Void)? { get set }
    var onTimedTranscript: (([TranscriptSpan]) -> Void)? { get set }
    var onLog: ((String, LogLevel) -> Void)? { get set }
    var onTranscriptionError: ((String) -> Void)? { get set }
    var onConnectionDropped: ((String) -> Void)? { get set }

    func connect(
        settings: TranscriptionProviderSettings,
        format: AudioStreamFormat,
        language: DeepgramLanguage
    )
    func sendAudio(data: Data)
    func closeStream(onClosed: @escaping () -> Void)
    func disconnect()
}

struct PasteboardSnapshotPayload: Equatable {
    let items: [[String: Data]]
}

protocol PasteboardPort {
    var changeToken: Int { get }
    func snapshot() -> PasteboardSnapshotPayload
    func writeString(_ value: String)
    func restore(_ snapshot: PasteboardSnapshotPayload)
    func sendPasteCommand() -> Bool
}

struct PreparedPasteVerification {
    let expectedText: String
    let expectedValue: String
    let expectedSelectedRange: NSRange
    let focusedElement: AXUIElement
    let initialValue: String
    let initialSelectedRange: NSRange
}

enum PasteVerificationCheck: Equatable {
    case confirmed
    case pending
    case unconfirmed(PasteVerificationFailureReason)
}

enum PasteVerificationFailureReason: Equatable {
    case accessibilityUnavailable
    case unsupportedFocusedElement
    case focusChanged
    case valueUnavailable
    case selectionUnavailable
    case mismatch
    case timedOut
}

protocol PasteVerificationPort {
    func prepare(expectedText: String) -> PreparedPasteVerification?
    func check(_ verification: PreparedPasteVerification) -> PasteVerificationCheck
}

protocol SoundPort {
    func play(named: String)
}

enum KeyboardMonitorEvent {
    case flagsChanged(keyCode: CGKeyCode, modifiers: NSEvent.ModifierFlags)
    case keyDown(keyCode: CGKeyCode)
}

protocol EventMonitorPort {
    func addKeyDownInterceptor(
        handler: @escaping (CGKeyCode) -> Bool
    ) -> Any?

    func addKeyboardMonitor(
        handler: @escaping (KeyboardMonitorEvent) -> Void
    ) -> Any?

    func removeMonitor(_ monitor: Any)
    func isHealthy(_ monitor: Any) -> Bool
}

extension EventMonitorPort {
    func isHealthy(_ monitor: Any) -> Bool { true }
}
