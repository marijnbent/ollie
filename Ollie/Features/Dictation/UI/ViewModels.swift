import Observation
import AppKit
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class DictationSettingsController {
    private let settingsStore: DictationSettingsStore
    private let permissionService: DictationPermissionService

    init(settingsStore: DictationSettingsStore, permissionService: DictationPermissionService) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        bind()
    }

    var microphonePermission: PermissionStatus { permissionService.microphonePermission }
    var accessibilityPermission: PermissionStatus { permissionService.accessibilityPermission }
    var availableAudioInputs: [AudioInputDeviceDescriptor] {
        _ = inputRevision
        return AudioInputCatalog.availableDevices()
    }
    var resolvedAudioInputSelection: ResolvedAudioInputSelection {
        AudioInputCatalog.resolvedSelection(settingsStore.audioInputSelection)
    }
    var deepgramLanguage: DeepgramLanguage { settingsStore.deepgramLanguage }
    var assemblyAIKeyError: String? { settingsStore.assemblyAIKeyError }
    var transcriptionProvider: TranscriptionProvider { settingsStore.transcriptionProvider }
    var selectedLanguage: DeepgramLanguage {
        settingsStore.transcriptionProvider.normalizedLanguage(settingsStore.deepgramLanguage)
    }
    var availableLanguages: [DeepgramLanguage] {
        settingsStore.transcriptionProvider.languageOptions
    }
    var supportsAutomaticLanguageCandidates: Bool {
        settingsStore.transcriptionProvider.supportsAutomaticLanguageCandidates
    }
    var automaticLanguageCandidateOptions: [DeepgramLanguage] {
        settingsStore.transcriptionProvider.automaticLanguageCandidateOptions
    }
    var automaticLanguageCandidates: [DeepgramLanguage] {
        settingsStore.transcriptionProvider.normalizedAutomaticLanguageCandidates(
            settingsStore.automaticLanguageCandidates
        )
    }
    var automaticLanguageCandidatesSummary: String {
        let names = automaticLanguageCandidates.map(\.displayName)
        if names.count <= 3 {
            return names.joined(separator: ", ")
        }
        return "\(names.count) languages"
    }
    var transcriptionLanguageHelpText: String {
        settingsStore.transcriptionProvider.automaticLanguageHelpText
    }
    var starredDeepgramLanguages: [DeepgramLanguage] { settingsStore.starredDeepgramLanguages }
    var appTranscriptionLanguageOverrides: [AppTranscriptionLanguageOverride] {
        settingsStore.appTranscriptionLanguageOverrides
    }
    var audioInputHelpText: String {
        let resolved = resolvedAudioInputSelection

        switch settingsStore.audioInputSelection {
        case .systemDefault:
            if let systemDefaultDevice = resolved.systemDefaultDevice {
                return "Uses the current macOS default microphone: \(systemDefaultDevice.name)."
            }
            return "Uses the current macOS default microphone for new recordings."
        case .device(let uniqueID):
            if let selectedDevice = resolved.selectedDevice {
                return "Uses \(selectedDevice.name) for new recordings, even if your macOS default changes."
            }
            if let systemDefaultDevice = resolved.systemDefaultDevice {
                return "The saved microphone is unavailable. New recordings will fall back to \(systemDefaultDevice.name) until it comes back."
            }
            return "The saved microphone (\(uniqueID)) is unavailable and no fallback input is currently available."
        }
    }

    func binding<Value>(for keyPath: ReferenceWritableKeyPath<DictationSettingsStore, Value>) -> Binding<Value> {
        Binding(
            get: { self.settingsStore[keyPath: keyPath] },
            set: { self.settingsStore[keyPath: keyPath] = $0 }
        )
    }

    func languageBinding() -> Binding<DeepgramLanguage> {
        Binding(
            get: { self.selectedLanguage },
            set: { self.settingsStore.deepgramLanguage = $0 }
        )
    }

    func isAutomaticLanguageCandidate(_ language: DeepgramLanguage) -> Bool {
        automaticLanguageCandidates.contains(language)
    }

    func canRemoveAutomaticLanguageCandidate(_ language: DeepgramLanguage) -> Bool {
        isAutomaticLanguageCandidate(language) && automaticLanguageCandidates.count > 2
    }

    func toggleAutomaticLanguageCandidate(_ language: DeepgramLanguage) {
        guard supportsAutomaticLanguageCandidates,
              automaticLanguageCandidateOptions.contains(language) else { return }

        var candidates = automaticLanguageCandidates
        if let index = candidates.firstIndex(of: language) {
            guard canRemoveAutomaticLanguageCandidate(language) else { return }
            candidates.remove(at: index)
        } else {
            candidates.append(language)
        }

        settingsStore.automaticLanguageCandidates = settingsStore.transcriptionProvider
            .normalizedAutomaticLanguageCandidates(candidates)
    }

    func bindingForAppTranscriptionLanguageOverrideID(
        _ overrideID: UUID
    ) -> Binding<AppTranscriptionLanguageOverride>? {
        guard let index = settingsStore.appTranscriptionLanguageOverrides.firstIndex(where: { $0.id == overrideID }) else {
            return nil
        }

        return Binding(
            get: {
                var override = self.settingsStore.appTranscriptionLanguageOverrides[index]
                override.language = self.settingsStore.transcriptionProvider.normalizedLanguage(override.language)
                return override
            },
            set: {
                var normalized = $0
                normalized.language = self.settingsStore.transcriptionProvider.normalizedLanguage(normalized.language)
                self.settingsStore.appTranscriptionLanguageOverrides[index] = normalized
            }
        )
    }

    func menuBarLanguages(matching query: String) -> [DeepgramLanguage] {
        DeepgramLanguage.sortedForSettings(
            availableLanguages.filter { $0.matchesSearch(query) },
            starred: Set(settingsStore.starredDeepgramLanguages.filter(availableLanguages.contains))
        )
    }

    func appOverrideLanguages(for currentLanguage: DeepgramLanguage) -> [DeepgramLanguage] {
        let starredLanguages = settingsStore.starredDeepgramLanguages
        let normalizedCurrentLanguage = settingsStore.transcriptionProvider.normalizedLanguage(currentLanguage)
        let availableStarredLanguages = starredLanguages.filter(availableLanguages.contains)
        let languages = availableStarredLanguages.contains(normalizedCurrentLanguage)
            ? availableStarredLanguages
            : availableStarredLanguages + [normalizedCurrentLanguage]
        return DeepgramLanguage.sortedForMenuBar(
            DeepgramLanguage.normalizedStarredLanguages(languages, fallback: [normalizedCurrentLanguage])
        )
    }

    func isLanguageStarred(_ language: DeepgramLanguage) -> Bool {
        settingsStore.starredDeepgramLanguages.contains(language)
    }

    func canToggleStarRemoval(for language: DeepgramLanguage) -> Bool {
        !isLanguageStarred(language) || settingsStore.starredDeepgramLanguages.count > 1
    }

    func toggleStar(for language: DeepgramLanguage) {
        if let index = settingsStore.starredDeepgramLanguages.firstIndex(of: language) {
            guard settingsStore.starredDeepgramLanguages.count > 1 else { return }
            settingsStore.starredDeepgramLanguages.remove(at: index)
            return
        }

        settingsStore.starredDeepgramLanguages.append(language)
    }

    func upsertAppTranscriptionLanguageOverride(
        appBundleIdentifier: String,
        appDisplayName: String,
        language: DeepgramLanguage? = nil
    ) {
        TranscriptionLanguageRoutingService.upsertAppOverride(
            appBundleIdentifier: appBundleIdentifier,
            appDisplayName: appDisplayName,
            language: language,
            settings: settingsStore
        )
    }

    func removeAppTranscriptionLanguageOverride(id: UUID) {
        settingsStore.appTranscriptionLanguageOverrides.removeAll { $0.id == id }
    }

    func refreshPermissions() {
        permissionService.refreshPermissions()
    }

    func requestMicrophonePermission() {
        permissionService.requestMicrophonePermission()
    }

    func requestAccessibilityPermission() {
        permissionService.requestAccessibilityPermission()
    }

    func microphonePermissionButtonTitle() -> String {
        switch permissionService.microphonePermission {
        case .authorized:
            return "Granted"
        case .notDetermined:
            return "Request"
        case .denied:
            return "Open Settings"
        }
    }

    func accessibilityPermissionButtonTitle() -> String {
        switch permissionService.accessibilityPermission {
        case .authorized:
            return "Granted"
        case .notDetermined:
            return "Request"
        case .denied:
            return "Open Settings"
        }
    }

    @ObservationIgnored private var inputObservers: [NotificationToken] = []
    private var inputRevision = 0
    private func bind() {
        let center = NotificationCenter.default
        inputObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationToken(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.inputRevision += 1 }
            }, center: center)
        }
    }

}

@MainActor
@Observable
final class DictationShortcutsController {
    private let settingsStore: DictationSettingsStore

    init(settingsStore: DictationSettingsStore) {
        self.settingsStore = settingsStore
    }

    var shortcuts: [ShortcutConfig] { settingsStore.shortcuts }
    var canAddShortcut: Bool { settingsStore.shortcuts.count < ShortcutKey.allCases.count }

    func binding(forShortcutID shortcutID: UUID) -> Binding<ShortcutConfig>? {
        guard let index = settingsStore.shortcuts.firstIndex(where: { $0.id == shortcutID }) else {
            return nil
        }
        return Binding(
            get: { self.settingsStore.shortcuts[index] },
            set: { self.settingsStore.shortcuts[index] = $0 }
        )
    }

    func usedKeys(excluding shortcutID: UUID) -> Set<ShortcutKey> {
        Set(settingsStore.shortcuts.filter { $0.id != shortcutID }.map(\.key))
    }

    func removeShortcut(id: UUID) {
        settingsStore.shortcuts.removeAll { $0.id == id }
    }

    func addShortcut() {
        let usedKeys = Set(settingsStore.shortcuts.map(\.key))
        if let nextKey = ShortcutKey.allCases.first(where: { !usedKeys.contains($0) }) {
            settingsStore.shortcuts.append(ShortcutConfig(id: UUID(), key: nextKey, mode: .both))
        }
    }
}

@MainActor
@Observable
final class DictationEnhancementsController {
    private let settingsStore: DictationSettingsStore
    private let promptRoutingService: PromptRoutingService

    init(settingsStore: DictationSettingsStore, promptRoutingService: PromptRoutingService) {
        self.settingsStore = settingsStore
        self.promptRoutingService = promptRoutingService
    }

    var prompts: [PromptConfig] { settingsStore.prompts }
    var shortcuts: [ShortcutConfig] { settingsStore.shortcuts }

    func binding<Value>(for keyPath: ReferenceWritableKeyPath<DictationSettingsStore, Value>) -> Binding<Value> {
        Binding(
            get: { self.settingsStore[keyPath: keyPath] },
            set: { self.settingsStore[keyPath: keyPath] = $0 }
        )
    }

    func bindingForPromptID(_ promptID: UUID) -> Binding<PromptConfig>? {
        guard let prompt = settingsStore.prompts.first(where: { $0.id == promptID }) else { return nil }
        return Binding(
            get: { self.settingsStore.prompts.first(where: { $0.id == promptID }) ?? prompt },
            set: { updated in
                guard let index = self.settingsStore.prompts.firstIndex(where: { $0.id == promptID }) else { return }
                self.settingsStore.prompts[index] = updated
            }
        )
    }

    func bindingForShortcutID(_ shortcutID: UUID) -> Binding<ShortcutConfig>? {
        guard let index = settingsStore.shortcuts.firstIndex(where: { $0.id == shortcutID }) else {
            return nil
        }
        return Binding(
            get: { self.settingsStore.shortcuts[index] },
            set: { self.settingsStore.shortcuts[index] = $0 }
        )
    }

    func addPrompt() -> PromptConfig {
        let previousPrompt = settingsStore.prompts.last
        let prompt = PromptConfig.makeDefault(
            provider: previousPrompt?.provider ?? .openRouter,
            model: previousPrompt?.model
        )
        settingsStore.prompts.append(prompt)
        return prompt
    }

    func deletePrompt(id: UUID) {
        promptRoutingService.deletePrompt(id: id, settings: settingsStore)
    }

    func upsertAppPromptOverride(
        shortcutID: UUID,
        appBundleIdentifier: String,
        appDisplayName: String,
        promptID: UUID? = nil
    ) {
        promptRoutingService.upsertAppPromptOverride(
            shortcutID: shortcutID,
            appBundleIdentifier: appBundleIdentifier,
            appDisplayName: appDisplayName,
            promptID: promptID,
            settings: settingsStore
        )
    }

    func promptUsageSummary(for promptID: UUID) -> String {
        let defaultShortcutCount = settingsStore.shortcuts.filter { $0.promptID == promptID }.count
        let overrideCount = settingsStore.shortcuts.reduce(0) { partialResult, shortcut in
            partialResult + shortcut.appPromptOverrides.filter { $0.promptID == promptID }.count
        }

        switch (defaultShortcutCount, overrideCount) {
        case (0, 0):
            return "Unused"
        case (_, 0):
            return defaultShortcutCount == 1
                ? "Used as the default for 1 shortcut"
                : "Used as the default for \(defaultShortcutCount) shortcuts"
        case (0, _):
            return overrideCount == 1
                ? "Used by 1 app override"
                : "Used by \(overrideCount) app overrides"
        default:
            let defaultText = defaultShortcutCount == 1
                ? "default for 1 shortcut"
                : "default for \(defaultShortcutCount) shortcuts"
            let overrideText = overrideCount == 1
                ? "1 app override"
                : "\(overrideCount) app overrides"
            return "Used as \(defaultText) and \(overrideText)"
        }
    }
}

@MainActor
@Observable
final class DictationHistoryController {
    typealias Enhancer = @Sendable (
        _ transcript: String,
        _ prompt: String,
        _ settings: EnhancementProviderSettings
    ) async throws -> String
    typealias Transcriber = @Sendable (
        _ fileURL: URL,
        _ settings: TranscriptionProviderSettings,
        _ language: DeepgramLanguage
    ) async throws -> String

    private let settingsStore: DictationSettingsStore
    private let sessionState: DictationSessionState
    private let enhancer: Enhancer
    private let transcriber: Transcriber

    private(set) var expandedHistoryEntries: Set<UUID> = []
    private(set) var retryingEntryIDs: Set<UUID> = []
    private(set) var retryErrors: [UUID: String] = [:]

    init(
        settingsStore: DictationSettingsStore,
        sessionState: DictationSessionState,
        enhancer: @escaping Enhancer = EnhancementClient.enhance,
        transcriber: @escaping Transcriber = PrerecordedTranscriptionClient.transcribe
    ) {
        self.settingsStore = settingsStore
        self.sessionState = sessionState
        self.enhancer = enhancer
        self.transcriber = transcriber
    }

    var transcriptHistory: [TranscriptHistoryEntry] {
        sessionState.transcriptHistory
    }

    var historyLimit: DictationHistoryLimit {
        settingsStore.historyLimit
    }

    var retryTranscriptionLanguages: [DeepgramLanguage] {
        let provider = settingsStore.transcriptionProvider
        let availableLanguages = provider.languageOptions
        return DeepgramLanguage.sortedForMenuBar(
            DeepgramLanguage.normalizedStarredLanguages(
                ([.automatic] + settingsStore.starredDeepgramLanguages).filter(availableLanguages.contains),
                fallback: [availableLanguages.first ?? .automatic]
            )
        )
    }

    func binding<Value>(for keyPath: ReferenceWritableKeyPath<DictationSettingsStore, Value>) -> Binding<Value> {
        Binding(
            get: { self.settingsStore[keyPath: keyPath] },
            set: { self.settingsStore[keyPath: keyPath] = $0 }
        )
    }

    func isExpanded(_ entryID: UUID) -> Bool {
        expandedHistoryEntries.contains(entryID)
    }

    func toggleExpansion(_ entryID: UUID) {
        if expandedHistoryEntries.contains(entryID) {
            expandedHistoryEntries.remove(entryID)
        } else {
            expandedHistoryEntries.insert(entryID)
        }
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func isRetrying(_ entryID: UUID) -> Bool {
        retryingEntryIDs.contains(entryID)
    }

    func retryError(for entryID: UUID) -> String? {
        retryErrors[entryID]
    }

    func retryEnhancement(for entry: TranscriptHistoryEntry) {
        guard entry.canRetryEnhancement else { return }
        guard beginRetry(for: entry.id, status: .enhancing) else { return }
        retryingEntryIDs.insert(entry.id)
        let providerSettings = settingsStore.enhancementProviderSettings(for: entry)
        sessionState.addLog(
            "Retrying enhancement from history " +
                "(provider: \(providerSettings.provider.displayName), model: \(providerSettings.model)).",
            level: .info
        )

        Task { [weak self] in
            guard let self else { return }
            let enhancementResult = await self.runEnhancement(
                transcript: entry.text,
                for: entry
            )
            await MainActor.run {
                self.applyRetryResult(
                    for: entry,
                    transcriptText: entry.text,
                    transcriptionError: entry.transcriptionError,
                    enhancedText: enhancementResult.enhancedText,
                    enhancementError: enhancementResult.enhancementError
                )
                self.finishRetry(for: entry.id)
            }
        }
    }

    func retryTranscription(for entry: TranscriptHistoryEntry, language: DeepgramLanguage) {
        guard entry.canRetryTranscription,
              let fileURL = entry.rawRecordingFileURL else { return }
        guard beginRetry(for: entry.id, status: .finalizing) else { return }

        retryingEntryIDs.insert(entry.id)
        let transcriptionSettings = settingsStore.transcriptionProviderSettings
        sessionState.addLog(
            "Retrying transcription with \(transcriptionSettings.provider.displayName) " +
                "from saved recording (language: \(language.displayName)).",
            level: .info
        )

        Task { [weak self] in
            guard let self else { return }

            guard !transcriptionSettings.apiKey.isEmpty else {
                await MainActor.run {
                    self.finishRetry(
                        for: entry.id,
                        error: "\(transcriptionSettings.provider.displayName) API key is not set.",
                        logLevel: .warning
                    )
                }
                return
            }

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                await MainActor.run {
                    self.finishRetry(for: entry.id, error: "Saved recording could not be found.")
                }
                return
            }

            do {
                let transcript = try await self.transcriber(
                    fileURL,
                    transcriptionSettings,
                    language
                ).trimmed
                if transcript.isEmpty {
                    await MainActor.run {
                        self.finishRetry(
                            for: entry.id,
                            error: "\(transcriptionSettings.provider.displayName) returned no transcript."
                        )
                    }
                    return
                }

                let enhancementResult = await self.runEnhancement(
                    transcript: transcript,
                    for: entry
                )

                await MainActor.run {
                    self.applyRetryResult(
                        for: entry,
                        transcriptText: transcript,
                        transcriptionError: nil,
                        enhancedText: enhancementResult.enhancedText,
                        enhancementError: enhancementResult.enhancementError,
                        transcriptionLanguage: language
                    )
                    self.sessionState.addLog("History transcription retry succeeded.", level: .info)
                    self.finishRetry(for: entry.id)
                }
            } catch {
                await MainActor.run {
                    let reason = error.localizedDescription.trimmed.isEmpty
                        ? String(describing: error)
                        : error.localizedDescription
                    self.finishRetry(for: entry.id, error: reason)
                }
            }
        }
    }

    private func applyRetryResult(
        for entry: TranscriptHistoryEntry,
        transcriptText: String,
        transcriptionError: String?,
        enhancedText: String?,
        enhancementError: String?,
        transcriptionLanguage: DeepgramLanguage? = nil
    ) {
        sessionState.updateTranscriptHistoryEntry(id: entry.id) { current in
            TranscriptHistoryEntry(
                id: current.id,
                timestamp: current.timestamp,
                text: transcriptText,
                enhancedText: enhancedText,
                transcriptionError: transcriptionError,
                enhancementError: enhancementError,
                promptName: current.promptName,
                enhancementPromptText: current.enhancementPromptText,
                enhancementProvider: current.enhancementProvider,
                enhancementModel: current.enhancementModel,
                rawRecordingFileURL: current.rawRecordingFileURL,
                transcriptionLanguage: transcriptionLanguage ?? current.transcriptionLanguage,
                usedActiveAppPrompt: current.usedActiveAppPrompt,
                sourceFileName: current.sourceFileName
            )
        }
    }

    private func beginRetry(for entryID: UUID, status: AppStatus) -> Bool {
        guard !retryingEntryIDs.contains(entryID) else { return false }
        retryErrors[entryID] = nil
        sessionState.appStatus = status
        return true
    }

    private func finishRetry(
        for entryID: UUID,
        error: String? = nil,
        logLevel: LogLevel = .error
    ) {
        if let error {
            retryErrors[entryID] = error
            sessionState.addLog("History transcription retry failed: \(error)", level: logLevel)
        }
        retryingEntryIDs.remove(entryID)
        if retryingEntryIDs.isEmpty {
            sessionState.appStatus = .idle
        }
    }

    private func runEnhancement(
        transcript: String,
        for entry: TranscriptHistoryEntry
    ) async -> (enhancedText: String?, enhancementError: String?) {
        guard let prompt = entry.enhancementPromptText?.trimmed, !prompt.isEmpty else {
            return (nil, nil)
        }

        let providerSettings = settingsStore.enhancementProviderSettings(for: entry)
        if let missing = providerSettings.missingCredential {
            let reason = "\(providerSettings.provider.displayName) \(missing) is not set."
            sessionState.addLog("History enhancement retry skipped: \(reason)", level: .warning)
            return (nil, reason)
        }

        await MainActor.run {
            sessionState.appStatus = .enhancing
        }

        do {
            let enhanced = try await enhancer(transcript, prompt, providerSettings)
            let trimmed = enhanced.trimmed
            if trimmed.isEmpty {
                sessionState.addLog(
                    "History enhancement retry failed (model: \(providerSettings.model)): " +
                        "\(providerSettings.provider.displayName) returned empty content.",
                    level: .error
                )
                return (nil, "\(providerSettings.provider.displayName) returned empty content.")
            }

            sessionState.addLog(
                "History enhancement retry succeeded (model: \(providerSettings.model)).",
                level: .info
            )
            return (trimmed, nil)
        } catch {
            let reason = error.localizedDescription.trimmed.isEmpty
                ? String(describing: error)
                : error.localizedDescription
            sessionState.addLog(
                "History enhancement retry failed (model: \(providerSettings.model)): \(reason)",
                level: .error
            )
            return (nil, reason)
        }
    }
}

@MainActor
@Observable
final class DictationLogsController {
    private let sessionState: DictationSessionState

    init(sessionState: DictationSessionState) {
        self.sessionState = sessionState
    }

    var logs: [LogEntry] {
        sessionState.logs
    }

    func clearLogs() {
        sessionState.clearLogs()
    }

    func copyLogEntry(_ entry: LogEntry) {
        let text = "\(DictationFormatters.formatter.string(from: entry.timestamp)) \(entry.level.rawValue) \(entry.message)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
