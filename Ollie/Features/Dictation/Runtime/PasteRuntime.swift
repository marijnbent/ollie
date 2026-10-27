import ApplicationServices
import Foundation

struct FinalizedTranscriptSession {
    let finalTranscript: String
    let lastTranscript: String
    let enhancementPrompt: EnhancementPromptContext?
    let transcriptionError: String?
    let rawRecordingFileURL: URL?
    let transcriptionLanguage: DeepgramLanguage?

    init(
        finalTranscript: String,
        lastTranscript: String,
        enhancementPrompt: EnhancementPromptContext?,
        transcriptionError: String?,
        rawRecordingFileURL: URL? = nil,
        transcriptionLanguage: DeepgramLanguage? = nil
    ) {
        self.finalTranscript = finalTranscript
        self.lastTranscript = lastTranscript
        self.enhancementPrompt = enhancementPrompt
        self.transcriptionError = transcriptionError
        self.rawRecordingFileURL = rawRecordingFileURL
        self.transcriptionLanguage = transcriptionLanguage
    }
}

struct PasteRuntimeSettings {
    enum Delivery { case paste, handOff }
    let enhancement: EnhancementProviderSettings?
    let playSoundEffects: Bool
    let restoreClipboardAfterPaste: Bool
    var delivery: Delivery = .paste
}

enum PasteRuntimeEvent {
    case status(AppStatus)
    case log(String, LogLevel)
    case historyEntry(TranscriptHistoryEntry)
    case hideOverlay
    case playSound(String)
}

@MainActor
final class PasteRuntime {
    struct Outcome {
        let recordingAdopted: Bool
        let text: String?
    }
    typealias Enhancer = @Sendable (
        _ transcript: String,
        _ prompt: String,
        _ settings: EnhancementProviderSettings
    ) async throws -> String

    private let pasteboard: PasteboardPort
    private let pasteVerification: PasteVerificationPort
    private let scheduler: SchedulerPort
    private let enhancer: Enhancer
    private let pasteVerificationPollInterval: TimeInterval
    private let pasteVerificationTimeout: TimeInterval

    private var pendingVerification: CancellableTask?
    private var writtenChangeToken: Int?

    func cancelPendingVerification() {
        pendingVerification?.cancel()
        pendingVerification = nil
        writtenChangeToken = nil
    }

    var onEvent: ((PasteRuntimeEvent) -> Void)?

    init(
        pasteboard: PasteboardPort,
        pasteVerification: PasteVerificationPort,
        scheduler: SchedulerPort,
        enhancer: @escaping Enhancer,
        pasteVerificationPollInterval: TimeInterval = 0.05,
        pasteVerificationTimeout: TimeInterval = 0.35
    ) {
        self.pasteboard = pasteboard
        self.pasteVerification = pasteVerification
        self.scheduler = scheduler
        self.enhancer = enhancer
        self.pasteVerificationPollInterval = pasteVerificationPollInterval
        self.pasteVerificationTimeout = pasteVerificationTimeout
    }

    @discardableResult
    func process(session: FinalizedTranscriptSession, settings: PasteRuntimeSettings) async -> Outcome {
        guard !Task.isCancelled else { return Outcome(recordingAdopted: false, text: nil) }
        var recordingAdopted = false
        var deliveredText: String?
        cancelPendingVerification()
        let finalText = session.finalTranscript.trimmed
        let fallbackText = session.lastTranscript.trimmed
        let rawText = finalText.isEmpty ? fallbackText : finalText

        guard !rawText.isEmpty else {
            let reason = session.transcriptionError ?? TranscriptHistoryEntry.emptyTranscriptionMessage
            emit(.status(.transcriptionFailed))
            emit(.log("Transcription failed: \(reason)", .error))
            emit(.historyEntry(
                TranscriptHistoryEntry(
                    timestamp: Date(),
                    text: "",
                    transcriptionError: reason,
                    rawRecordingFileURL: session.rawRecordingFileURL,
                    transcriptionLanguage: session.transcriptionLanguage
                )
            ))
            emit(.hideOverlay)
            if settings.playSoundEffects || session.transcriptionError != nil {
                emit(.playSound(session.transcriptionError != nil ? "Basso" : "Pop"))
            }
            return Outcome(recordingAdopted: true, text: nil)
        }

        defer {
            emit(.hideOverlay)
        }

        do {
            try Task.checkCancellation()

            var enhancedText: String?
            var enhancementFailed = false
            var enhancementError: String?

            if let prompt = session.enhancementPrompt {
                let enhancementSettings = settings.enhancement ?? EnhancementProviderSettings(
                    provider: prompt.provider,
                    apiKey: "",
                    model: prompt.model
                )
                if let missing = enhancementSettings.missingCredential {
                    let reason = "\(enhancementSettings.provider.displayName) \(missing) is not set."
                    emit(.status(.enhancementSkippedMissing(missing)))
                    emit(.log("Enhancement skipped: \(reason)", .warning))
                    enhancementError = reason
                    enhancementFailed = true
                } else {
                    let requestStart = Date()
                    emit(.status(.enhancing))
                    emit(.log(
                        "Sending transcript to \(enhancementSettings.provider.displayName) for enhancement " +
                            "(model: \(enhancementSettings.model)).",
                        .info
                    ))
                    do {
                        let enhanced = try await enhancer(
                            rawText,
                            prompt.content,
                            enhancementSettings
                        )
                        try Task.checkCancellation()

                        let latencyMs = Int(Date().timeIntervalSince(requestStart) * 1_000)
                        let trimmed = enhanced.trimmed
                        if !trimmed.isEmpty {
                            enhancedText = trimmed
                            emit(.log(
                                "Transcript enhanced successfully " +
                                    "(model: \(enhancementSettings.model), \(latencyMs) ms).",
                                .info
                            ))
                        } else {
                            emit(.status(.enhancementFailedPastingOriginal))
                            emit(.log(
                                "Enhancement failed (model: \(enhancementSettings.model), \(latencyMs) ms): " +
                                    "\(enhancementSettings.provider.displayName) returned empty content.",
                                .error
                            ))
                            enhancementError = "\(enhancementSettings.provider.displayName) returned empty content."
                            enhancementFailed = true
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let latencyMs = Int(Date().timeIntervalSince(requestStart) * 1_000)
                        let reason = error.localizedDescription.trimmed.isEmpty
                            ? String(describing: error)
                            : error.localizedDescription
                        emit(.status(.enhancementFailedPastingOriginal))
                        emit(.log(
                            "Enhancement failed (model: \(enhancementSettings.model), \(latencyMs) ms): \(reason)",
                            .error
                        ))
                        enhancementError = reason
                        enhancementFailed = true
                    }
                }
            }

            try Task.checkCancellation()

            let textToPaste = enhancedText ?? rawText

            emit(.historyEntry(
                TranscriptHistoryEntry(
                    timestamp: Date(),
                    text: rawText,
                    enhancedText: enhancedText,
                    transcriptionError: session.transcriptionError,
                    enhancementError: enhancementError,
                    promptName: session.enhancementPrompt?.name,
                    enhancementPromptText: session.enhancementPrompt?.content,
                    enhancementProvider: session.enhancementPrompt?.provider,
                    enhancementModel: session.enhancementPrompt?.model,
                    rawRecordingFileURL: session.rawRecordingFileURL,
                    transcriptionLanguage: session.transcriptionLanguage,
                    usedActiveAppPrompt: session.enhancementPrompt?.isForActiveApp ?? false
                )
            ))
            recordingAdopted = true
            deliveredText = textToPaste

            if settings.delivery == .handOff {
                emit(.status(.idle))
                return Outcome(recordingAdopted: true, text: textToPaste)
            }

            let snapshot = settings.restoreClipboardAfterPaste ? pasteboard.snapshot() : nil
            let preparedVerification = settings.restoreClipboardAfterPaste
                ? pasteVerification.prepare(expectedText: textToPaste)
                : nil
            pasteboard.writeString(textToPaste)
            writtenChangeToken = pasteboard.changeToken

            if let transcriptionError = session.transcriptionError {
                emit(.log("Transcript completed with warning: \(transcriptionError)", .warning))
                if settings.playSoundEffects || session.transcriptionError != nil {
                    emit(.playSound("Basso"))
                }
            }
            if enhancementFailed {
                emit(.log("Pasted original transcription because enhancement failed.", .warning))
            }
            emit(.log("Transcript copied to clipboard.", .info))
            emit(.status(.idle))

            try Task.checkCancellation()

            if !AXIsProcessTrusted() {
                emit(.log("Accessibility permission not granted. Enable it to allow paste automation.", .warning))
            }

            let didAutoPaste = pasteboard.sendPasteCommand()
            guard didAutoPaste else {
                emit(.log("Failed to send paste command (Cmd+V).", .error))
                if settings.playSoundEffects || enhancementFailed {
                    emit(.playSound(enhancementFailed ? "Basso" : "Pop"))
                }
                return Outcome(recordingAdopted: recordingAdopted, text: deliveredText)
            }

            emit(.log("Paste command sent (Cmd+V).", .info))

            if settings.playSoundEffects || enhancementFailed {
                emit(.playSound(enhancementFailed ? "Basso" : "Pop"))
            }

            guard settings.restoreClipboardAfterPaste, let snapshot else {
                return Outcome(recordingAdopted: recordingAdopted, text: deliveredText)
            }
            guard let preparedVerification else {
                emit(.log("Could not confirm auto-paste. Kept transcript on the clipboard.", .warning))
                return Outcome(recordingAdopted: recordingAdopted, text: deliveredText)
            }

            schedulePasteVerification(
                preparedVerification,
                snapshot: snapshot,
                remainingAttempts: verificationAttemptCount
            )
        } catch is CancellationError {
            emit(.status(.cancelled))
            emit(.log("Recording cancelled.", .info))
        } catch {
            emit(.status(.cancelled))
            emit(.log("Recording cancelled.", .info))
        }
        return Outcome(recordingAdopted: recordingAdopted, text: deliveredText)
    }

    private func emit(_ event: PasteRuntimeEvent) {
        onEvent?(event)
    }

    private var verificationAttemptCount: Int {
        max(1, Int(ceil(pasteVerificationTimeout / pasteVerificationPollInterval)))
    }

    private func schedulePasteVerification(
        _ verification: PreparedPasteVerification,
        snapshot: PasteboardSnapshotPayload,
        remainingAttempts: Int
    ) {
        pendingVerification = scheduler.schedule(after: pasteVerificationPollInterval) { [weak self] in
            self?.performPasteVerification(
                verification,
                snapshot: snapshot,
                remainingAttempts: remainingAttempts
            )
        }
    }

    private func performPasteVerification(
        _ verification: PreparedPasteVerification,
        snapshot: PasteboardSnapshotPayload,
        remainingAttempts: Int
    ) {
        guard writtenChangeToken == pasteboard.changeToken else { cancelPendingVerification(); return }
        switch pasteVerification.check(verification) {
        case .confirmed:
            cancelPendingVerification()
            pasteboard.restore(snapshot)
            emit(.log("Auto-paste confirmed. Restored previous clipboard.", .info))
        case .pending:
            guard remainingAttempts > 1 else {
                handlePasteVerificationFailure(.timedOut)
                return
            }
            schedulePasteVerification(
                verification,
                snapshot: snapshot,
                remainingAttempts: remainingAttempts - 1
            )
        case .unconfirmed(let reason):
            handlePasteVerificationFailure(reason)
        }
    }

    private func handlePasteVerificationFailure(_ reason: PasteVerificationFailureReason) {
        guard reason != .timedOut else {
            emit(.log("Could not confirm auto-paste. Kept transcript on the clipboard.", .warning))
            return
        }
        emit(.log("Could not confirm auto-paste. Kept transcript on the clipboard.", .warning))
    }
}
