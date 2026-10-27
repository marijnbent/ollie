import AppKit
import Observation

@MainActor
@Observable
final class DictationCoordinator: HealthCheckable {
    let settings = DictationSettingsStore()
    let session: DictationSessionState
    let permissions = DictationPermissionService()
    let prompts = PromptRoutingService()
    private unowned let core: AppCore
    private let ticker: HealthTicker
    @ObservationIgnored private let history = TranscriptHistoryStore()
    @ObservationIgnored private let recordings = RawRecordingStore()
    @ObservationIgnored private let events = CGEventMonitorAdapter()
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var historyLoaded = false
    @ObservationIgnored private lazy var windows = DictationWindowCoordinator(settings: settings, session: session) { [weak self] in
        self?.core.settingsCoordinator.showSettings(tab: .dictation)
    }
    @ObservationIgnored private lazy var runtime = DictationRuntimeCoordinator(
        settingsStore: settings, sessionState: session, permissionService: permissions,
        promptRoutingService: prompts, windowCoordinator: windows, rawRecordingStore: recordings,
        schedulerPort: DictationScheduler(), clockPort: SystemClockAdapter(), soundPort: NSSoundAdapter(),
        pasteboardPort: NSPasteboardAdapter(), pasteVerificationPort: AccessibilityPasteVerificationAdapter(),
        audioCapturePort: AudioCaptureControllerAdapter(controller: AudioCaptureController(preferredInputProvider: { [weak self] in
            self?.settings.audioInputSelection ?? .systemDefault
        })), transcriptionStreamPort: TranscriptionStreamRouter(), eventMonitorPort: events,
        isEnabled: { [weak self] in self?.core.settings.dictationEnabled == true },
        activeApplicationProvider: {
            let app = NSWorkspace.shared.frontmostApplication
            return ActiveApplicationContext(bundleIdentifier: app?.bundleIdentifier, icon: app?.icon)
        })
    @ObservationIgnored private lazy var escape = EscCancelMonitor(
        eventMonitor: events, isEnabled: { [weak self] in self?.settings.escToCancelRecording == true },
        shouldCancel: { [weak self] in self?.runtime.canCancelFromEsc == true },
        cancelRecording: { [weak self] in self?.runtime.cancelFromEsc() })
    @ObservationIgnored private(set) lazy var generalControls = DictationSettingsController(settingsStore: settings, permissionService: permissions)
    @ObservationIgnored private(set) lazy var shortcutControls = DictationShortcutsController(settingsStore: settings)
    @ObservationIgnored private(set) lazy var enhancementControls = DictationEnhancementsController(settingsStore: settings, promptRoutingService: prompts)
    @ObservationIgnored private(set) lazy var historyControls = DictationHistoryController(settingsStore: settings, sessionState: session)
    @ObservationIgnored private(set) lazy var logControls = DictationLogsController(sessionState: session)
    private(set) var isRunning = false
    private(set) var isProcessing = false
    private(set) var conflict: String?
    var isCapturingShortcut = false { didSet { apply() } }
    var isBusy: Bool { session.recordingPhase != .idle || isProcessing }

    init(core: AppCore, ticker: HealthTicker) {
        self.core = core
        self.ticker = ticker
        session = DictationSessionState(historyStore: history, initialHistoryIsPersisted: false)
        session.onHistoryEntriesRemoved = { [weak self] entries in
            for entry in entries { self?.recordings.deleteRecording(at: entry.rawRecordingFileURL) }
        }
        session.onHistoryPersistenceError = { [weak self] message in self?.session.addLog(message, level: .error) }
    }

    var reservedBindings: [HotKeyBinding] {
        guard core.settings.dictationEnabled else { return [] }
        return settings.shortcuts.flatMap { shortcut -> [HotKeyBinding] in
            let key: ModifierKey = switch shortcut.key {
            case .fn: .globe
            case .leftControl: .leftControl
            case .leftCommand: .leftCommand
            case .rightCommand: .rightCommand
            case .rightOption: .rightOption
            }
            return [key.singleBinding, key.doubleBinding] + (key.modifier.map { [.doubleTap($0)] } ?? [])
        }
    }

    func prepareSettings() {
        settings.loadCredentials()
        permissions.refreshPermissions()
        loadHistory()
    }

    private func loadHistory() {
        guard !historyLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            do {
                let entries = try await Task.detached(priority: .utility) { [history] in try history.loadEntries() }.value
                guard !Task.isCancelled, core.settings.dictationEnabled else { return }
                session.loadHistory(entries)
                session.applyHistoryLimit(settings.historyLimit)
                historyLoaded = true
            } catch {
                guard !Task.isCancelled, core.settings.dictationEnabled else { return }
                session.reportHistoryLoadFailure()
            }
        }
    }

    func apply() {
        generation += 1
        let revision = generation
        conflict = reservedBindings.compactMap { core.hotKeys.conflictOwner(of: $0, includeReservations: false) }.first
        guard core.settings.dictationEnabled, !isCapturingShortcut, conflict == nil else {
            stop()
            return
        }
        settings.loadCredentials()
        loadHistory()
        ticker.subscribe(self)
        if isRunning { runtime.applySettings(); return }
        transition?.cancel()
        transition = Task { [weak self] in
            guard let self else { return }
            await loadTask?.value
            guard !Task.isCancelled, revision == generation else { return }
            if !historyLoaded {
                loadHistory()
                await loadTask?.value
                guard !Task.isCancelled, revision == generation else { return }
            }
            await runtime.finishStopping()
            guard !Task.isCancelled, revision == generation else { return }
            runtime.onProcessingChanged = { [weak self] busy in self?.isProcessing = busy }
            runtime.applySettings()
            if !isRunning {
                runtime.start()
                escape.start()
                isRunning = true
            }
        }
    }

    func applySettings() {
        apply()
    }

    func healthCheck() {
        guard core.settings.dictationEnabled else { return }
        permissions.refreshPermissions()
        guard isRunning else { return }
        runtime.recoverMonitor()
        escape.recoverMonitor()
    }

    func toggleRecording() {
        guard core.settings.dictationEnabled, isRunning else {
            core.settingsCoordinator.showSettings(tab: .dictation)
            return
        }
        runtime.toggleFromMenu()
    }

    func cancelRecording() { runtime.cancelFromEsc() }

    func beginHandOff(_ delivery: TranscriptHandOff) -> TranscriptHandOff.Start {
        guard isRunning else { return .unavailable("Enable and configure Dictation first.") }
        return runtime.beginHandOff(delivery)
    }

    func handOffUnavailableReason() -> String? {
        guard isRunning else { return "Enable and configure Dictation first." }
        return runtime.handOffUnavailableReason()
    }

    func endHandOff(id: UUID) { runtime.endHandOff(id: id) }
    func cancelHandOff(id: UUID) { runtime.cancelHandOff(id: id) }

    func stop() {
        generation += 1
        loadTask?.cancel()
        transition?.cancel()
        transition = nil
        ticker.unsubscribe(self)
        runtime.stop()
        escape.stop()
        isRunning = false
    }

    func prepareForTermination() async -> Bool {
        stop()
        await loadTask?.value
        await runtime.finishStopping()
        if !historyLoaded, session.transcriptHistory.isEmpty { return true }
        return await session.flushHistory()
    }
}
