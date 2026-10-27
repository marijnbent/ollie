import AppKit
import Foundation

@MainActor
final class DictationRuntimeCoordinator {
    private let settingsStore: DictationSettingsStore
    private let sessionState: DictationSessionState
    private let permissionService: DictationPermissionService
    private let promptRoutingService: PromptRoutingService
    private let windowCoordinator: DictationWindowCoordinator
    private let soundPort: SoundPort
    private let systemMuteController: SystemMuteController
    private let rawRecordingStore: RawRecordingStore
    private let isEnabled: () -> Bool

    private let shortcutRuntime: ShortcutRuntime
    private let recordingRuntime: RecordingRuntime
    private let pasteRuntime: PasteRuntime

    private var pasteTask: Task<Void, Never>?
    private var pasteGeneration = 0
    private var handOff: TranscriptHandOff?
    var onProcessingChanged: ((Bool) -> Void)?

    init(
        settingsStore: DictationSettingsStore,
        sessionState: DictationSessionState,
        permissionService: DictationPermissionService,
        promptRoutingService: PromptRoutingService,
        windowCoordinator: DictationWindowCoordinator,
        rawRecordingStore: RawRecordingStore,
        schedulerPort: SchedulerPort,
        clockPort: ClockPort,
        soundPort: SoundPort,
        pasteboardPort: PasteboardPort,
        pasteVerificationPort: PasteVerificationPort,
        audioCapturePort: AudioCapturePort,
        transcriptionStreamPort: TranscriptionStreamPort,
        eventMonitorPort: EventMonitorPort,
        isEnabled: @escaping () -> Bool,
        activeApplicationProvider: @escaping () -> ActiveApplicationContext?
    ) {
        self.isEnabled = isEnabled
        self.settingsStore = settingsStore
        self.sessionState = sessionState
        self.permissionService = permissionService
        self.promptRoutingService = promptRoutingService
        self.windowCoordinator = windowCoordinator
        self.soundPort = soundPort
        self.rawRecordingStore = rawRecordingStore
        self.systemMuteController = SystemMuteController { [weak sessionState] message, level in
            sessionState?.addLog(message, level: level)
        }

        self.pasteRuntime = PasteRuntime(
            pasteboard: pasteboardPort,
            pasteVerification: pasteVerificationPort,
            scheduler: schedulerPort,
            enhancer: { transcript, prompt, settings in
                try await EnhancementClient.enhance(
                    transcript: transcript,
                    prompt: prompt,
                    settings: settings
                )
            }
        )

        self.recordingRuntime = RecordingRuntime(
            audioCapture: audioCapturePort,
            transcriptionStream: transcriptionStreamPort,
            scheduler: schedulerPort,
            clock: clockPort,
            activeApplicationProvider: activeApplicationProvider,
            audioInputSelectionProvider: { [weak settingsStore] in
                AudioInputCatalog.resolvedSelection(settingsStore?.audioInputSelection ?? .systemDefault)
            },
            resolvedTranscriptionLanguageProvider: { [weak settingsStore] activeAppBundleIdentifier in
                guard let settingsStore else { return .automatic }
                return TranscriptionLanguageRoutingService.resolvedLanguage(
                    settings: settingsStore,
                    activeAppBundleIdentifier: activeAppBundleIdentifier
                )
            },
            transcriptionSettingsProvider: { [weak settingsStore] in
                settingsStore?.transcriptionProviderSettings
                    ?? TranscriptionProviderSettings(provider: .deepgram, apiKey: "")
            },
            resolvedEnhancementPromptProvider: { [weak settingsStore, weak promptRoutingService] shortcutID, activeAppBundleIdentifier in
                guard let settingsStore, let promptRoutingService, let shortcutID else { return nil }
                return promptRoutingService.resolvedEnhancementPrompt(
                    forShortcutID: shortcutID,
                    settings: settingsStore,
                    activeAppBundleIdentifier: activeAppBundleIdentifier
                )
            },
            playSoundEffectsEnabledProvider: { [weak settingsStore] in
                settingsStore?.playSoundEffects ?? false
            },
            muteDuringRecordingProvider: { [weak settingsStore] in
                settingsStore?.muteMediaDuringRecording ?? false
            },
            rawRecordingCaptureProvider: { [weak rawRecordingStore] format in
                rawRecordingStore?.makeCapture(format: format) ?? RawRecordingStore().makeCapture(format: format)
            },
            soundPort: soundPort
        )

        self.shortcutRuntime = ShortcutRuntime(
            eventMonitor: eventMonitorPort,
            clock: clockPort,
            clickHoldThreshold: 0.2
        )

        bindRuntimes()
        applySettings()
    }

    var canCancelFromEsc: Bool {
        handOff == nil && (recordingRuntime.phase != .idle || pasteTask != nil)
    }

    func recoverMonitor() { shortcutRuntime.recoverMonitor() }

    func start() {
        guard isEnabled() else { return }
        shortcutRuntime.configure(shortcuts: settingsStore.shortcuts)
        shortcutRuntime.start()
    }

    func stop() {
        recordingRuntime.cancelFromEsc()
        abandonHandOff()
        pasteTask?.cancel()
        pasteRuntime.cancelPendingVerification()
        systemMuteController.restoreMute()
        shortcutRuntime.stop()
    }

    func finishStopping() async {
        await recordingRuntime.waitForShutdown()
        await pasteTask?.value
        windowCoordinator.hideOverlay()
    }

    func toggleFromMenu() {
        if recordingRuntime.phase == .recording { recordingRuntime.handle(action: .stop); return }
        guard recordingRuntime.phase == .idle, pasteTask == nil else { return }
        let id = settingsStore.shortcuts.first?.id ?? UUID()
        handleShortcutActions([.start(ownerShortcutID: id, ownerMode: .click, latched: true)])
    }

    func beginHandOff(_ delivery: TranscriptHandOff) -> TranscriptHandOff.Start {
        if let issue = handOffUnavailableReason() { return .unavailable(issue) }
        handOff = delivery
        recordingRuntime.startUnenhanced(ownerShortcutID: delivery.id)
        return .started
    }

    func handOffUnavailableReason() -> String? {
        guard isEnabled() else { return "Enable Dictation first." }
        guard recordingRuntime.phase == .idle, pasteTask == nil, handOff == nil else {
            return "Finish the current dictation first."
        }
        permissionService.refreshPermissions()
        guard permissionService.microphonePermission == .authorized else {
            return "Allow Microphone access in Dictation settings first."
        }
        guard !settingsStore.transcriptionProviderSettings.apiKey.isEmpty else {
            return "Add a speech-to-text API key in Dictation settings first."
        }
        return nil
    }

    func endHandOff(id: UUID) {
        guard handOff?.id == id else { return }
        recordingRuntime.handle(action: .stop)
    }

    func cancelHandOff(id: UUID) {
        guard handOff?.id == id else { return }
        handOff = nil
        recordingRuntime.cancelFromEsc()
        pasteTask?.cancel()
        pasteRuntime.cancelPendingVerification()
    }

    private func abandonHandOff() {
        let abandoned = handOff
        handOff = nil
        abandoned?.finish(.cancelled)
    }

    func cancelFromEsc() {
        if recordingRuntime.phase != .idle {
            recordingRuntime.cancelFromEsc()
            return
        }

        pasteTask?.cancel()
        pasteRuntime.cancelPendingVerification()
        abandonHandOff()
    }

    func applySettings() {
        shortcutRuntime.configure(shortcuts: settingsStore.shortcuts)
        sessionState.applyHistoryLimit(settingsStore.historyLimit)
        recordingRuntime.changeTranscriptionLanguage(to: settingsStore.deepgramLanguage)
    }

    private func bindRuntimes() {
        recordingRuntime.onAbandoned = { [weak self] in self?.abandonHandOff() }
        shortcutRuntime.phaseProvider = { [weak self] in
            self?.recordingRuntime.phase ?? .idle
        }
        shortcutRuntime.ownershipProvider = { [weak self] in
            self?.recordingRuntime.ownership
        }
        shortcutRuntime.onActions = { [weak self] actions in
            self?.handleShortcutActions(actions)
        }
        shortcutRuntime.onCycleLanguage = { [weak self] in
            self?.cycleLanguage()
        }
        windowCoordinator.onCycleLanguage = { [weak self] in
            self?.cycleLanguage()
        }

        recordingRuntime.onWillStartRecording = { [weak self] in
            self?.sessionState.resetTranscript()
        }
        recordingRuntime.onStatus = { [weak self] status in
            self?.sessionState.appStatus = status
        }
        recordingRuntime.onLog = { [weak self] message, level in
            self?.sessionState.addLog(message, level: level)
        }
        recordingRuntime.onPhaseChanged = { [weak self] phase in
            self?.sessionState.recordingPhase = phase
        }
        recordingRuntime.onOverlayUpdate = { [weak self] visible, label, appIcon in
            guard let self else { return }
            guard self.handOff == nil else { return }
            if visible {
                self.windowCoordinator.showOverlay(label: label, appIcon: appIcon)
            } else {
                self.windowCoordinator.hideOverlay()
            }
        }
        recordingRuntime.onAudioLevel = { [weak self] level in
            self?.sessionState.audioMeter.update(level)
        }
        recordingRuntime.onTranscript = { [weak self] text, isFinal in
            self?.sessionState.handleTranscript(text, isFinal: isFinal)
        }
        recordingRuntime.onFinalizeLatestInterim = { [weak self] in
            self?.sessionState.finalizeLatestInterimTranscript()
        }
        recordingRuntime.onRequestOpenSettings = { [weak self] in
            guard let self, self.isEnabled() else { return }
            self.windowCoordinator.showSettings()
        }
        recordingRuntime.onMuteForRecording = { [weak self] in
            self?.systemMuteController.muteForRecording()
        }
        recordingRuntime.onRestoreMute = { [weak self] in
            self?.systemMuteController.restoreMute()
        }
        recordingRuntime.onFinalizeRequested = { [weak self] finalization in
            guard let self else { return }
            guard self.isEnabled() else {
                self.rawRecordingStore.deleteRecording(at: finalization.rawRecordingFileURL)
                return
            }
            self.pasteTask?.cancel()
            self.pasteGeneration += 1
            let generation = self.pasteGeneration
            let delivery = self.handOff
            if delivery != nil { self.sessionState.finalizeLatestInterimTranscript() }
            self.onProcessingChanged?(true)
            self.pasteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.pasteGeneration == generation {
                        self.pasteTask = nil
                        self.onProcessingChanged?(false)
                    }
                }
                guard !Task.isCancelled, self.isEnabled() else {
                    self.rawRecordingStore.deleteRecording(at: finalization.rawRecordingFileURL)
                    return
                }
                let outcome = await self.pasteRuntime.process(
                    session: FinalizedTranscriptSession(
                        finalTranscript: self.sessionState.finalTranscript,
                        lastTranscript: self.sessionState.lastTranscript,
                        enhancementPrompt: finalization.enhancementPrompt,
                        transcriptionError: finalization.transcriptionError,
                        rawRecordingFileURL: finalization.rawRecordingFileURL,
                        transcriptionLanguage: finalization.transcriptionLanguage
                    ),
                    settings: PasteRuntimeSettings(
                        enhancement: finalization.enhancementPrompt.map {
                            self.settingsStore.enhancementProviderSettings(for: $0)
                        },
                        playSoundEffects: self.settingsStore.playSoundEffects,
                        restoreClipboardAfterPaste: self.settingsStore.restoreClipboardAfterPaste,
                        delivery: delivery == nil ? .paste : .handOff
                    )
                )
                if !outcome.recordingAdopted {
                    self.rawRecordingStore.deleteRecording(at: finalization.rawRecordingFileURL)
                }
                guard !Task.isCancelled, let delivery, self.handOff?.id == delivery.id else { return }
                self.handOff = nil
                if let text = outcome.text {
                    delivery.finish(.transcript(text, warning: finalization.transcriptionError))
                } else {
                    delivery.finish(.failed(finalization.transcriptionError ?? TranscriptHistoryEntry.emptyTranscriptionMessage))
                }
            }
        }

        pasteRuntime.onEvent = { [weak self] event in
            self?.handlePasteRuntimeEvent(event)
        }
    }

    private func handleShortcutActions(_ actions: [ShortcutAction]) {
        guard isEnabled() else { stop(); return }
        guard handOff == nil else { return }
        for action in actions {
            if shouldRequestMicrophonePermission(for: action) {
                requestMicrophonePermissionForRecording()
                continue
            }

            recordingRuntime.handle(action: action)
        }
    }

    private func cycleLanguage() {
        guard handOff == nil else { return }
        let provider = settingsStore.transcriptionProvider
        let currentLanguage = provider.normalizedLanguage(settingsStore.deepgramLanguage)
        let language = DeepgramLanguage.nextStarredLanguage(
            after: currentLanguage,
            starredLanguages: settingsStore.starredDeepgramLanguages,
            availableLanguages: provider.languageOptions
        )
        guard language != currentLanguage else { return }

        settingsStore.deepgramLanguage = language
        if recordingRuntime.phase != .recording {
            sessionState.addLog("Language changed to \(language.displayName).", level: .info)
        }
    }

    private func shouldRequestMicrophonePermission(for action: ShortcutAction) -> Bool {
        guard case .start = action else { return false }
        permissionService.refreshPermissions()
        return permissionService.microphonePermission != .authorized
    }

    private func requestMicrophonePermissionForRecording() {
        sessionState.appStatus = .microphonePermissionRequired
        sessionState.addLog("Microphone access is required before Talkie can start recording.", level: .warning)
        windowCoordinator.showSettings()
        permissionService.requestMicrophonePermission()
    }

    private func handlePasteRuntimeEvent(_ event: PasteRuntimeEvent) {
        switch event {
        case .status(let status):
            sessionState.appStatus = status
        case .log(let message, let level):
            sessionState.addLog(message, level: level)
        case .historyEntry(let entry):
            sessionState.storeTranscriptHistoryEntry(entry, limit: settingsStore.historyLimit)
        case .hideOverlay:
            windowCoordinator.hideOverlay()
        case .playSound(let name):
            soundPort.play(named: name)
        }
    }
}
