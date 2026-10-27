import Foundation
import AppKit

struct ActiveApplicationContext {
    let bundleIdentifier: String?
    let icon: NSImage?
}

struct EnhancementPromptContext: Equatable {
    let name: String
    let content: String
    let isForActiveApp: Bool
    let provider: EnhancementProvider
    let model: String

    init(
        name: String,
        content: String,
        isForActiveApp: Bool,
        provider: EnhancementProvider = .openRouter,
        model: String = EnhancementProvider.openRouter.defaultModel
    ) {
        self.name = name
        self.content = content
        self.isForActiveApp = isForActiveApp
        self.provider = provider
        self.model = model
    }
}

struct RecordingFinalization {
    let transcriptSpans: [TranscriptSpan]
    let enhancementPrompt: EnhancementPromptContext?
    let transcriptionError: String?
    let rawRecordingFileURL: URL?
    let transcriptionLanguage: DeepgramLanguage?
}

private final class RecordingAudioRouter: @unchecked Sendable {
    private let transcriptionStream: TranscriptionStreamPort
    private let lock = NSLock()
    private let publishInterval: UInt64 = 33_000_000

    private var sessionID: UUID?
    private var rawCapture: RawRecordingCapture?
    private var smoothedLevel: Float = 0
    private var lastPublishedLevel: Float = 0
    private var lastPublishTime: UInt64 = 0
    private var levelHandler: (@Sendable (UUID, Float) -> Void)?

    init(transcriptionStream: TranscriptionStreamPort) {
        self.transcriptionStream = transcriptionStream
    }

    var onLevel: (@Sendable (UUID, Float) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return levelHandler
        }
        set {
            lock.lock()
            levelHandler = newValue
            lock.unlock()
        }
    }

    func activate(sessionID: UUID, rawCapture: RawRecordingCapture) {
        lock.lock()
        self.sessionID = sessionID
        self.rawCapture = rawCapture
        smoothedLevel = 0
        lastPublishedLevel = 0
        lastPublishTime = 0
        lock.unlock()
    }

    func deactivate(sessionID: UUID) {
        lock.lock()
        guard self.sessionID == sessionID else {
            lock.unlock()
            return
        }
        self.sessionID = nil
        rawCapture = nil
        lock.unlock()
    }

    func route(sessionID: UUID, chunk: Linear16AudioChunk) {
        lock.lock()
        guard self.sessionID == sessionID, let rawCapture else {
            lock.unlock()
            return
        }

        rawCapture.append(data: chunk.data)
        transcriptionStream.sendAudio(data: chunk.data)

        smoothedLevel = (smoothedLevel * 0.78) + (chunk.meterLevel * 0.22)
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldPublish = lastPublishTime == 0
            || now - lastPublishTime >= publishInterval
            || abs(smoothedLevel - lastPublishedLevel) >= 0.12
        let handler = levelHandler
        let publishedLevel = smoothedLevel
        if shouldPublish {
            lastPublishedLevel = publishedLevel
            lastPublishTime = now
        }
        lock.unlock()

        if shouldPublish {
            handler?(sessionID, publishedLevel)
        }
    }
}

@MainActor
final class RecordingRuntime {
    private let audioCapture: AudioCapturePort
    private let transcriptionStream: TranscriptionStreamPort
    private let audioRouter: RecordingAudioRouter
    private let scheduler: SchedulerPort
    private let clock: ClockPort

    private let activeApplicationProvider: () -> ActiveApplicationContext?
    private let audioInputSelectionProvider: () -> ResolvedAudioInputSelection
    private let resolvedTranscriptionLanguageProvider: (String?) -> DeepgramLanguage
    private let transcriptionSettingsProvider: () -> TranscriptionProviderSettings
    private let resolvedEnhancementPromptProvider: (UUID?, String?) -> EnhancementPromptContext?
    private let playSoundEffectsEnabledProvider: () -> Bool
    private let muteDuringRecordingProvider: () -> Bool
    private let rawRecordingCaptureProvider: (AudioStreamFormat) -> RawRecordingCapture
    private let soundPort: SoundPort

    private let stopDelay: TimeInterval
    private let reconnectDelay: TimeInterval
    private let finalizeWatchdogTimeout: TimeInterval
    private let maxReconnectAttempts: Int

    private var stopTask: CancellableTask?
    private var reconnectTask: CancellableTask?
    private var finalizeWatchdogTask: CancellableTask?
    private var captureStartTask: Task<Void, Never>?
    private var captureStopTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    private(set) var phase: RecordingPhase = .idle {
        didSet { onPhaseChanged?(phase) }
    }

    private(set) var ownership: RecordingOwnership? {
        didSet { onOwnershipChanged?(ownership) }
    }

    private var currentRecordingFormat: AudioStreamFormat?
    private var currentActiveApplication: ActiveApplicationContext?
    private var pendingTranscriptionError: String?
    private var pendingEnhancementPrompt: EnhancementPromptContext?
    private var pendingTranscriptionLanguage: DeepgramLanguage?
    private var pendingTranscriptionSettings: TranscriptionProviderSettings?
    private var rawRecordingCapture: RawRecordingCapture?
    private var transcriptionReconnectAttempt = 0
    private var hasPlayedTranscriptionFailureSound = false
    private var didFinalizeCurrentSession = false
    private var pendingStopAfterCaptureStart = false

    var onStatus: ((AppStatus) -> Void)?
    var onLog: ((String, LogLevel) -> Void)?
    var onPhaseChanged: ((RecordingPhase) -> Void)?
    var onOwnershipChanged: ((RecordingOwnership?) -> Void)?
    var onOverlayUpdate: ((Bool, String, NSImage?) -> Void)?
    var onAudioLevel: ((CGFloat) -> Void)?
    private var transcriptSpans: [TranscriptSpan] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onWillStartRecording: (() -> Void)?
    var onFinalizeLatestInterim: (() -> Void)?
    var onFinalizeRequested: ((RecordingFinalization) -> Void)?
    var onRequestOpenSettings: (() -> Void)?
    var onMuteForRecording: (() -> Void)?
    var onRestoreMute: (() -> Void)?
    var onAbandoned: (() -> Void)?

    init(
        audioCapture: AudioCapturePort,
        transcriptionStream: TranscriptionStreamPort,
        scheduler: SchedulerPort,
        clock: ClockPort,
        activeApplicationProvider: @escaping () -> ActiveApplicationContext?,
        audioInputSelectionProvider: @escaping () -> ResolvedAudioInputSelection,
        resolvedTranscriptionLanguageProvider: @escaping (String?) -> DeepgramLanguage,
        transcriptionSettingsProvider: @escaping () -> TranscriptionProviderSettings,
        resolvedEnhancementPromptProvider: @escaping (UUID?, String?) -> EnhancementPromptContext?,
        playSoundEffectsEnabledProvider: @escaping () -> Bool,
        muteDuringRecordingProvider: @escaping () -> Bool,
        rawRecordingCaptureProvider: @escaping (AudioStreamFormat) -> RawRecordingCapture = { format in
            RawRecordingStore().makeCapture(format: format)
        },
        soundPort: SoundPort,
        stopDelay: TimeInterval = 0.2,
        reconnectDelay: TimeInterval = 0.4,
        finalizeWatchdogTimeout: TimeInterval = 1.2,
        maxReconnectAttempts: Int = TranscriptionReconnectPolicy.maxAttempts
    ) {
        self.audioCapture = audioCapture
        self.transcriptionStream = transcriptionStream
        self.audioRouter = RecordingAudioRouter(transcriptionStream: transcriptionStream)
        self.scheduler = scheduler
        self.clock = clock
        self.activeApplicationProvider = activeApplicationProvider
        self.audioInputSelectionProvider = audioInputSelectionProvider
        self.resolvedTranscriptionLanguageProvider = resolvedTranscriptionLanguageProvider
        self.transcriptionSettingsProvider = transcriptionSettingsProvider
        self.resolvedEnhancementPromptProvider = resolvedEnhancementPromptProvider
        self.playSoundEffectsEnabledProvider = playSoundEffectsEnabledProvider
        self.muteDuringRecordingProvider = muteDuringRecordingProvider
        self.rawRecordingCaptureProvider = rawRecordingCaptureProvider
        self.soundPort = soundPort
        self.stopDelay = stopDelay
        self.reconnectDelay = reconnectDelay
        self.finalizeWatchdogTimeout = finalizeWatchdogTimeout
        self.maxReconnectAttempts = maxReconnectAttempts

        let audioRouter = self.audioRouter
        audioRouter.onLevel = { [weak self] sessionID, level in
            Task { @MainActor in
                guard let self, self.ownership?.sessionID == sessionID, self.phase == .recording else {
                    return
                }
                self.onAudioLevel?(CGFloat(level))
            }
        }
        self.audioCapture.onAudioChunk = { [weak audioRouter] sessionID, chunk in
            audioRouter?.route(sessionID: sessionID, chunk: chunk)
        }
        self.audioCapture.onConfigurationChanged = { [weak self] sessionID in
            Task { @MainActor in
                self?.handleAudioInputConfigurationChanged(sessionID: sessionID)
            }
        }
        self.transcriptionStream.onTranscriptEvent = { [weak self] text, isFinal in
            Task { @MainActor in
                self?.handleTranscriptEvent(text, isFinal: isFinal)
            }
        }
        self.transcriptionStream.onLog = { [weak self] message, level in
            Task { @MainActor in
                self?.onLog?(message, level)
            }
        }
        self.transcriptionStream.onTranscriptionError = { [weak self] message in
            Task { @MainActor in
                self?.handleTranscriptionError(message)
            }
        }
        self.transcriptionStream.onConnectionDropped = { [weak self] reason in
            Task { @MainActor in
                self?.handleTranscriptionConnectionDropped(reason: reason)
            }
        }
    }

    func handle(actions: [ShortcutAction]) {
        for action in actions {
            handle(action: action)
        }
    }

    func handle(action: ShortcutAction) {
        switch action {
        case .start(let ownerShortcutID, let ownerMode, let latched):
            startRecording(ownerShortcutID: ownerShortcutID, ownerMode: ownerMode, isLatched: latched)
        case .stop:
            stopRecording()
        case .cancel:
            cancelRecording()
        case .discard:
            discardRecording()
        case .scheduleStop:
            scheduleStopRecording()
        case .setLatched(let latched):
            guard var ownership else { return }
            ownership.isLatched = latched
            self.ownership = ownership
        case .noop:
            break
        }
    }

    func waitForShutdown() async { await cleanupTask?.value }

    func cancelFromEsc() {
        cancelRecording()
    }

    func startUnenhanced(ownerShortcutID: UUID) {
        startRecording(ownerShortcutID: ownerShortcutID, ownerMode: .click, isLatched: true, enhance: false, includeTimings: true)
    }

    func changeTranscriptionLanguage(to language: DeepgramLanguage) {
        guard phase == .recording else { return }
        guard let format = currentRecordingFormat else { return }
        guard let settings = pendingTranscriptionSettings, !settings.apiKey.isEmpty else { return }
        let normalizedLanguage = settings.provider.normalizedLanguage(language)
        guard pendingTranscriptionLanguage != normalizedLanguage else { return }

        cancelReconnect()
        onFinalizeLatestInterim?()
        pendingTranscriptionLanguage = normalizedLanguage
        pendingTranscriptionError = nil
        transcriptionReconnectAttempt = 0
        onStatus?(.listening)
        prepareTranscriptionTiming()
        transcriptionStream.connect(settings: settings, format: format, language: normalizedLanguage)
        onLog?("Language changed to \(normalizedLanguage.displayName).", .info)
    }

    private func startRecording(ownerShortcutID: UUID, ownerMode: ShortcutMode, isLatched: Bool,
                                enhance: Bool = true, includeTimings: Bool = false) {
        guard phase == .idle else { return }

        var transcriptionSettings = transcriptionSettingsProvider()
        transcriptionSettings.includeTimings = includeTimings
        guard !transcriptionSettings.apiKey.isEmpty else {
            onStatus?(.missingAPIKey)
            onLog?("Missing \(transcriptionSettings.provider.displayName) API key. Open Settings to add one.", .warning)
            onRequestOpenSettings?()
            return
        }

        cancelPendingStop()
        cancelReconnect()
        cancelFinalizeWatchdog()

        pendingTranscriptionError = nil
        pendingEnhancementPrompt = nil
        pendingTranscriptionLanguage = nil
        pendingTranscriptionSettings = transcriptionSettings
        currentActiveApplication = nil
        hasPlayedTranscriptionFailureSound = false
        transcriptionReconnectAttempt = 0
        didFinalizeCurrentSession = false
        pendingStopAfterCaptureStart = false
        onWillStartRecording?()

        let activeApplication = activeApplicationProvider()
        currentActiveApplication = activeApplication
        pendingEnhancementPrompt = enhance ? resolvedEnhancementPromptProvider(
            ownerShortcutID,
            activeApplication?.bundleIdentifier
        ) : nil
        let transcriptionLanguage = resolvedTranscriptionLanguageProvider(activeApplication?.bundleIdentifier)
        pendingTranscriptionLanguage = transcriptionLanguage

        transcriptSpans.removeAll()
        let sessionID = UUID()
        ownership = RecordingOwnership(
            ownerShortcutID: ownerShortcutID,
            ownerMode: ownerMode,
            isLatched: isLatched,
            recordingStartedAt: clock.now(),
            sessionID: sessionID
        )
        phase = .recording

        captureStartTask = Task { @MainActor [weak self] in
            await self?.completeCaptureStart(
                sessionID: sessionID,
                transcriptionSettings: transcriptionSettings,
                transcriptionLanguage: transcriptionLanguage
            )
        }
    }

    private func completeCaptureStart(
        sessionID: UUID,
        transcriptionSettings: TranscriptionProviderSettings,
        transcriptionLanguage: DeepgramLanguage
    ) async {
        do {
            let format = try await audioCapture.start(sessionID: sessionID)
            try Task.checkCancellation()
            guard ownership?.sessionID == sessionID, phase == .recording else {
                await audioCapture.stop(sessionID: sessionID)
                return
            }

            captureStartTask = nil
            currentRecordingFormat = format
            let rawCapture = rawRecordingCaptureProvider(format)
            rawRecordingCapture = rawCapture
            prepareTranscriptionTiming()
            audioRouter.activate(sessionID: sessionID, rawCapture: rawCapture)

            let resolvedAudioInput = audioInputSelectionProvider()
            onStatus?(.listening)
            onOverlayUpdate?(true, "Listening", overlayAppIcon)
            onLog?("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", .info)
            if resolvedAudioInput.isFallbackToSystemDefault {
                onLog?("Input: \(resolvedAudioInput.displayName). Saved microphone unavailable, using fallback.", .warning)
            } else {
                onLog?("Input: \(resolvedAudioInput.displayName).", .info)
            }
            transcriptionStream.connect(
                settings: transcriptionSettings,
                format: format,
                language: transcriptionLanguage
            )

            if muteDuringRecordingProvider() {
                onMuteForRecording?()
            }
            playSound("Tink")
            onLog?("Provider: \(transcriptionSettings.provider.displayName).", .info)
            onLog?("Language: \(transcriptionLanguage.displayName).", .info)
            onLog?("Listening started.", .info)

            if pendingStopAfterCaptureStart {
                pendingStopAfterCaptureStart = false
                stopRecording()
            }
        } catch is CancellationError {
        } catch {
            guard ownership?.sessionID == sessionID, phase == .recording else { return }
            captureStartTask = nil
            finishActiveSession(
                disconnectTranscriptionStream: true,
                clearPendingTranscriptionError: true,
                hideOverlay: true
            )
            onStatus?(.failedToStartAudioCapture(error.localizedDescription))
            onLog?("Failed to start audio capture: \(error.localizedDescription)", .error)
        }
    }

    private func stopRecording() {
        guard phase == .recording else { return }

        cancelPendingStop()
        cancelReconnect()

        guard let sessionID = ownership?.sessionID else { return }
        guard currentRecordingFormat != nil else {
            pendingStopAfterCaptureStart = true
            return
        }

        audioRouter.deactivate(sessionID: sessionID)
        phase = .finalizing
        onAudioLevel?(0)
        onStatus?(.finalizing)
        onRestoreMute?()

        if pendingEnhancementPrompt != nil {
            onOverlayUpdate?(true, "Enhancing", overlayAppIcon)
        } else {
            onOverlayUpdate?(true, "Listening", nil)
        }

        didFinalizeCurrentSession = false
        captureStopTask?.cancel()
        captureStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.audioCapture.stop(sessionID: sessionID)
            guard !Task.isCancelled,
                  self.ownership?.sessionID == sessionID,
                  self.phase == .finalizing else {
                return
            }
            self.captureStopTask = nil
            self.startFinalizeWatchdog()
            self.transcriptionStream.closeStream { [weak self] in
                Task { @MainActor in
                    guard self?.ownership?.sessionID == sessionID else { return }
                    self?.finalizeIfNeeded()
                }
            }
        }
    }

    private func finalizeIfNeeded() {
        guard phase == .finalizing else { return }
        guard !didFinalizeCurrentSession else { return }
        guard let sessionID = ownership?.sessionID else { return }

        didFinalizeCurrentSession = true
        cancelFinalizeWatchdog()
        let capture = rawRecordingCapture
        rawRecordingCapture = nil
        let enhancementPrompt = pendingEnhancementPrompt
        let transcriptionError = pendingTranscriptionError
        let transcriptionLanguage = pendingTranscriptionLanguage

        finalizationTask = Task { @MainActor [weak self] in
            let recordingURL: URL?
            do {
                recordingURL = try await capture?.finish()
            } catch {
                recordingURL = nil
                if let self, self.ownership?.sessionID == sessionID {
                    self.onLog?("Failed to save raw recording: \(error.localizedDescription)", .error)
                }
            }

            guard let self,
                  !Task.isCancelled,
                  self.ownership?.sessionID == sessionID,
                  self.phase == .finalizing else {
                capture?.discard()
                return
            }

            self.finalizationTask = nil
            let finalization = RecordingFinalization(
                transcriptSpans: self.transcriptSpans,
                enhancementPrompt: enhancementPrompt,
                transcriptionError: transcriptionError,
                rawRecordingFileURL: recordingURL,
                transcriptionLanguage: transcriptionLanguage
            )
            self.finishActiveSession(
                disconnectTranscriptionStream: true,
                clearPendingTranscriptionError: false,
                hideOverlay: false,
                abandoned: false
            )
            self.onFinalizeRequested?(finalization)
        }
    }

    private func startFinalizeWatchdog() {
        cancelFinalizeWatchdog()
        let providerTimeout: TimeInterval = pendingTranscriptionSettings?.provider == .assemblyAI ? 15.5 : 3.5
        let timeout = max(finalizeWatchdogTimeout, providerTimeout)
        finalizeWatchdogTask = scheduler.schedule(after: timeout) { [weak self] in
            Task { @MainActor in
                self?.finalizeIfNeeded()
            }
        }
    }

    private func cancelFinalizeWatchdog() {
        finalizeWatchdogTask?.cancel()
        finalizeWatchdogTask = nil
    }

    private func prepareTranscriptionTiming() {
        guard pendingTranscriptionSettings?.includeTimings == true, let sessionID = ownership?.sessionID else {
            transcriptionStream.onTimedTranscript = nil
            return
        }
        let origin = clock.now()
        transcriptionStream.onTimedTranscript = { [weak self] spans in
            Task { @MainActor [weak self] in
                guard let self, self.ownership?.sessionID == sessionID else { return }
                self.transcriptSpans.append(contentsOf: spans.filter(\.isValid).map { $0.shifted(by: origin) })
            }
        }
    }

    private func handleTranscriptEvent(_ text: String, isFinal: Bool) {
        let wasRecovering = transcriptionReconnectAttempt > 0 || reconnectTask != nil
        if wasRecovering {
            cancelReconnect()
            transcriptionReconnectAttempt = 0
            if phase == .recording {
                onStatus?(.listening)
            }
            if pendingTranscriptionError != nil {
                pendingTranscriptionError = nil
                let provider = pendingTranscriptionSettings?.provider.displayName ?? "Transcription"
                onLog?("\(provider) connection recovered. Transcription resumed.", .info)
            }
        }

        onTranscript?(text, isFinal)
    }

    private func handleTranscriptionError(_ message: String) {
        let isFirstErrorInSession = pendingTranscriptionError == nil
        pendingTranscriptionError = message
        if phase != .idle {
            onStatus?(.transcriptionIssueDetected)
        }
        if isFirstErrorInSession,
           phase != .idle,
           !hasPlayedTranscriptionFailureSound {
            playErrorSound(force: true)
            hasPlayedTranscriptionFailureSound = true
        }
    }

    private func handleTranscriptionConnectionDropped(reason: String) {
        guard phase == .recording else { return }
        guard currentRecordingFormat != nil else { return }
        guard reconnectTask == nil else { return }

        if pendingTranscriptionError == nil {
            handleTranscriptionError(reason)
        }
        onFinalizeLatestInterim?()

        let provider = pendingTranscriptionSettings?.provider.displayName ?? "Transcription"
        if !TranscriptionReconnectPolicy.shouldRetry(currentAttempt: transcriptionReconnectAttempt) {
            onStatus?(.connectionLostReleaseToFinalize)
            onLog?(
                "\(provider) reconnect limit reached (\(maxReconnectAttempts) attempts). Last error: \(reason)",
                .error
            )
            return
        }

        transcriptionReconnectAttempt += 1
        let attempt = transcriptionReconnectAttempt
        let delayText = String(format: "%.1f", reconnectDelay)
        onStatus?(.connectionRecovering)
        onLog?(
            "\(provider) connection dropped. Reconnecting in \(delayText)s (attempt \(attempt)/\(maxReconnectAttempts)).",
            .warning
        )

        reconnectTask = scheduler.schedule(after: reconnectDelay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectTask = nil
                guard self.phase == .recording else { return }
                guard let format = self.currentRecordingFormat else { return }
                guard let settings = self.pendingTranscriptionSettings,
                      !settings.apiKey.isEmpty else { return }

                self.onLog?(
                    "Attempting \(settings.provider.displayName) reconnect (\(attempt)/\(self.maxReconnectAttempts)).",
                    .warning
                )
                let language = self.pendingTranscriptionLanguage
                    ?? self.resolvedTranscriptionLanguageProvider(self.currentActiveApplication?.bundleIdentifier)
                self.prepareTranscriptionTiming()
                self.transcriptionStream.connect(settings: settings, format: format, language: language)
            }
        }
    }

    private func handleAudioInputConfigurationChanged(sessionID: UUID) {
        guard ownership?.sessionID == sessionID else { return }
        onLog?("Audio input changed. Capture engine reset.", .warning)
        guard phase != .idle else { return }

        finishActiveSession(disconnectTranscriptionStream: true, clearPendingTranscriptionError: true, hideOverlay: true)
        onStatus?(.inputChangedReady)
        onLog?("Recording stopped because the input device changed.", .warning)
    }

    private func cancelRecording() {
        guard phase != .idle else { return }

        finishActiveSession(disconnectTranscriptionStream: true, clearPendingTranscriptionError: true, hideOverlay: true)
        playSound("Pop")
        onStatus?(.cancelled)
        onLog?("Recording cancelled.", .info)
    }

    private func discardRecording() {
        guard phase == .recording else { return }

        finishActiveSession(disconnectTranscriptionStream: true, clearPendingTranscriptionError: true, hideOverlay: true)
        onStatus?(.idle)
    }

    private func scheduleStopRecording() {
        cancelPendingStop()
        stopTask = scheduler.schedule(after: stopDelay) { [weak self] in
            Task { @MainActor in
                self?.stopRecording()
            }
        }
    }

    private func cancelPendingStop() {
        stopTask?.cancel()
        stopTask = nil
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func finishActiveSession(
        disconnectTranscriptionStream: Bool,
        clearPendingTranscriptionError: Bool,
        hideOverlay: Bool,
        abandoned: Bool = true
    ) {
        let sessionID = ownership?.sessionID
        cancelPendingStop()
        cancelReconnect()
        cancelFinalizeWatchdog()
        pendingStopAfterCaptureStart = false
        let previousStart = captureStartTask
        captureStartTask?.cancel()
        captureStartTask = nil
        let previousStop = captureStopTask
        captureStopTask?.cancel()
        captureStopTask = nil
        let previousFinalization = finalizationTask
        finalizationTask?.cancel()
        finalizationTask = nil

        if let sessionID {
            audioRouter.deactivate(sessionID: sessionID)
            let audioCapture = self.audioCapture
            let previousCleanup = cleanupTask
            cleanupTask = Task {
                await previousCleanup?.value
                await previousStart?.value
                await previousStop?.value
                await previousFinalization?.value
                await audioCapture.stop(sessionID: sessionID)
            }
        }

        if disconnectTranscriptionStream {
            transcriptionStream.disconnect()
        }

        rawRecordingCapture?.discard()
        rawRecordingCapture = nil

        phase = .idle
        ownership = nil
        currentRecordingFormat = nil
        transcriptSpans.removeAll()
        transcriptionStream.onTimedTranscript = nil
        currentActiveApplication = nil
        pendingEnhancementPrompt = nil
        pendingTranscriptionLanguage = nil
        pendingTranscriptionSettings = nil
        transcriptionReconnectAttempt = 0
        didFinalizeCurrentSession = false
        onRestoreMute?()
        onAudioLevel?(0)

        if hideOverlay {
            onOverlayUpdate?(false, "Listening", nil)
        }

        if clearPendingTranscriptionError {
            pendingTranscriptionError = nil
            hasPlayedTranscriptionFailureSound = false
        }
        if abandoned, sessionID != nil { onAbandoned?() }
    }

    private func playSound(_ name: String) {
        guard playSoundEffectsEnabledProvider() else { return }
        soundPort.play(named: name)
    }

    private func playErrorSound(force: Bool = false) {
        guard force || playSoundEffectsEnabledProvider() else { return }
        soundPort.play(named: "Basso")
    }

    private var overlayAppIcon: NSImage? {
        guard pendingEnhancementPrompt?.isForActiveApp == true else { return nil }
        return currentActiveApplication?.icon
    }
}
