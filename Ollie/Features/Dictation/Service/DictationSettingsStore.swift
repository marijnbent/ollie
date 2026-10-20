import Observation
import Foundation

@MainActor
@Observable
final class DictationSettingsStore {
    static let apiKeyKey = "Talkie.ApiKey"
    static let transcriptionProviderKey = "Talkie.TranscriptionProvider"
    static let elevenLabsApiKeyKey = "Talkie.ElevenLabsApiKey"
    static let museApiKeyKey = "Talkie.MuseApiKey"
    static let deepgramLanguageKey = "Talkie.DeepgramLanguage"
    static let automaticLanguageCandidatesKey = "Talkie.AutomaticLanguageCandidates"
    static let starredDeepgramLanguagesKey = "Talkie.StarredDeepgramLanguages"
    static let historyLimitKey = "Talkie.HistoryLimit"
    static let shortcutsKey = "Talkie.Shortcuts"
    static let enhancementProviderKey = "Talkie.EnhancementProvider"
    static let openRouterApiKeyKey = "Talkie.OpenRouterApiKey"
    static let openRouterModelKey = "Talkie.OpenRouterModel"
    static let celerisApiKeyKey = "Talkie.CelerisApiKey"
    static let promptsKey = "Talkie.Prompts"
    static let legacyEnhancementPromptsKey = "Talkie.EnhancementPrompts"
    static let escToCancelRecordingKey = "Talkie.EscToCancelRecording"
    static let playSoundEffectsKey = "Talkie.PlaySoundEffects"
    static let muteMediaDuringRecordingKey = "Talkie.MuteMediaDuringRecording"
    static let restoreClipboardAfterPasteKey = "Talkie.RestoreClipboardAfterPaste"
    static let showSelectedLanguageInMenuBarKey = "Talkie.ShowSelectedLanguageInMenuBar"
    static let showLanguageInRecorderWidgetKey = "Talkie.ShowLanguageInRecorderWidget"
    static let showLiveTranscriptInRecorderWidgetKey = "Talkie.ShowLiveTranscriptInRecorderWidget"
    static let overlayPositionKey = "Talkie.OverlayPosition"
    static let audioInputSelectionKey = "Talkie.AudioInputSelection"
    static let appTranscriptionLanguageOverridesKey = "Talkie.AppTranscriptionLanguageOverrides"

    private(set) var credentialError: String?
    @ObservationIgnored private var credentialsLoaded = false
    @ObservationIgnored private var isLoadingCredentials = false

    func loadCredentials() {
        guard !credentialsLoaded else { return }
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        do {
            apiKey = try DictationCredential.store.secret(for: DictationCredential.deepgram.account) ?? ""
            elevenLabsApiKey = try DictationCredential.store.secret(for: DictationCredential.elevenLabs.account) ?? ""
            assemblyAIApiKey = try DictationCredential.store.secret(for: DictationCredential.assemblyAI.account) ?? ""
            museApiKey = try DictationCredential.store.secret(for: DictationCredential.muse.account) ?? ""
            openRouterApiKey = try DictationCredential.store.secret(for: DictationCredential.openRouter.account) ?? ""
            celerisApiKey = try DictationCredential.store.secret(for: DictationCredential.celeris.account) ?? ""
            mercuryApiKey = try DictationCredential.store.secret(for: DictationCredential.mercury.account) ?? ""
            credentialsLoaded = true
            credentialError = nil
        } catch { credentialError = "Could not read dictation keys from Keychain." }
    }

    private func saveCredential(_ secret: String, kind: DictationCredential) {
        guard !isLoadingCredentials else { return }
        do {
            if secret.trimmed.isEmpty {
                try DictationCredential.store.removeSecret(for: kind.account)
            } else {
                try DictationCredential.store.setSecret(secret.trimmed, for: kind.account)
            }
            credentialError = nil
            assemblyAIKeyError = nil
        } catch {
            credentialError = "Could not save the dictation key in Keychain."
            if kind == .assemblyAI { assemblyAIKeyError = credentialError }
        }
    }

    private let defaults: UserDefaults

    var apiKey: String {
        didSet {
            saveCredential(apiKey, kind: .deepgram)
        }
    }

    var transcriptionProvider: TranscriptionProvider {
        didSet {
            defaults.set(transcriptionProvider.rawValue, forKey: Self.transcriptionProviderKey)
        }
    }

    var elevenLabsApiKey: String {
        didSet {
            saveCredential(elevenLabsApiKey, kind: .elevenLabs)
        }
    }

    var assemblyAIApiKey: String {
        didSet {
            saveCredential(assemblyAIApiKey, kind: .assemblyAI)
        }
    }

    private(set) var assemblyAIKeyError: String?

    var museApiKey: String {
        didSet {
            saveCredential(museApiKey, kind: .muse)
        }
    }

    var shortcuts: [ShortcutConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: Self.shortcutsKey)
            }
        }
    }

    var openRouterApiKey: String {
        didSet {
            saveCredential(openRouterApiKey, kind: .openRouter)
        }
    }

    var celerisApiKey: String {
        didSet {
            saveCredential(celerisApiKey, kind: .celeris)
        }
    }

    var mercuryApiKey: String {
        didSet {
            saveCredential(mercuryApiKey, kind: .mercury)
        }
    }

    var prompts: [PromptConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(prompts) {
                defaults.set(data, forKey: Self.promptsKey)
            }
        }
    }

    var escToCancelRecording: Bool {
        didSet {
            defaults.set(escToCancelRecording, forKey: Self.escToCancelRecordingKey)
        }
    }

    var playSoundEffects: Bool {
        didSet {
            defaults.set(playSoundEffects, forKey: Self.playSoundEffectsKey)
        }
    }

    var muteMediaDuringRecording: Bool {
        didSet {
            defaults.set(muteMediaDuringRecording, forKey: Self.muteMediaDuringRecordingKey)
        }
    }

    var restoreClipboardAfterPaste: Bool {
        didSet {
            defaults.set(restoreClipboardAfterPaste, forKey: Self.restoreClipboardAfterPasteKey)
        }
    }

    var showSelectedLanguageInMenuBar: Bool {
        didSet {
            defaults.set(showSelectedLanguageInMenuBar, forKey: Self.showSelectedLanguageInMenuBarKey)
        }
    }

    var showLanguageInRecorderWidget: Bool {
        didSet {
            defaults.set(showLanguageInRecorderWidget, forKey: Self.showLanguageInRecorderWidgetKey)
        }
    }

    var showLiveTranscriptInRecorderWidget: Bool {
        didSet {
            defaults.set(showLiveTranscriptInRecorderWidget, forKey: Self.showLiveTranscriptInRecorderWidgetKey)
        }
    }

    var overlayPosition: OverlayPosition {
        didSet {
            defaults.set(overlayPosition.rawValue, forKey: Self.overlayPositionKey)
        }
    }

    var audioInputStoredValue: String {
        get { audioInputSelection.storedValue }
        set { audioInputSelection = AudioInputSelection(storedValue: newValue) }
    }

    var audioInputSelection: AudioInputSelection {
        didSet {
            defaults.set(audioInputSelection.storedValue, forKey: Self.audioInputSelectionKey)
        }
    }

    var deepgramLanguage: DeepgramLanguage {
        didSet {
            defaults.set(deepgramLanguage.rawValue, forKey: Self.deepgramLanguageKey)
        }
    }

    var automaticLanguageCandidates: [DeepgramLanguage] {
        didSet {
            let normalized = TranscriptionProvider.elevenLabs.normalizedAutomaticLanguageCandidates(
                automaticLanguageCandidates
            )
            if normalized != automaticLanguageCandidates {
                automaticLanguageCandidates = normalized
                return
            }

            defaults.set(normalized.map(\.rawValue), forKey: Self.automaticLanguageCandidatesKey)
        }
    }

    var starredDeepgramLanguages: [DeepgramLanguage] {
        didSet {
            let normalized = DeepgramLanguage.normalizedStarredLanguages(
                starredDeepgramLanguages,
                fallback: oldValue.isEmpty ? DeepgramLanguage.defaultStarredLanguages : oldValue
            )

            if normalized != starredDeepgramLanguages {
                starredDeepgramLanguages = normalized
                return
            }

            defaults.set(normalized.map(\.rawValue), forKey: Self.starredDeepgramLanguagesKey)
        }
    }

    var historyLimit: DictationHistoryLimit {
        didSet {
            defaults.set(historyLimit.rawValue, forKey: Self.historyLimitKey)
        }
    }

    var appTranscriptionLanguageOverrides: [AppTranscriptionLanguageOverride] {
        didSet {
            if let data = try? JSONEncoder().encode(appTranscriptionLanguageOverrides) {
                defaults.set(data, forKey: Self.appTranscriptionLanguageOverridesKey)
            }
        }
    }

    func enhancementProviderSettings(
        provider: EnhancementProvider,
        model: String
    ) -> EnhancementProviderSettings {
        switch provider {
        case .openRouter:
            EnhancementProviderSettings(
                provider: .openRouter,
                apiKey: openRouterApiKey.trimmed,
                model: model.trimmed
            )
        case .celeris:
            EnhancementProviderSettings(
                provider: .celeris,
                apiKey: celerisApiKey.trimmed,
                model: model.trimmed
            )
        case .mercury:
            EnhancementProviderSettings(
                provider: .mercury,
                apiKey: mercuryApiKey.trimmed,
                model: model.trimmed
            )
        }
    }

    func enhancementProviderSettings(for prompt: EnhancementPromptContext) -> EnhancementProviderSettings {
        enhancementProviderSettings(provider: prompt.provider, model: prompt.model)
    }

    func enhancementProviderSettings(for entry: TranscriptHistoryEntry) -> EnhancementProviderSettings {
        let provider = entry.enhancementProvider ?? legacyEnhancementProvider
        let savedModel = (entry.enhancementModel?.trimmed)
            .flatMap { $0.isEmpty ? nil : $0 }
        let model = savedModel ?? legacyModel(for: provider)
        return enhancementProviderSettings(provider: provider, model: model)
    }

    var transcriptionProviderSettings: TranscriptionProviderSettings {
        let apiKey = switch transcriptionProvider {
        case .deepgram:
            apiKey
        case .elevenLabs:
            elevenLabsApiKey
        case .muse:
            museApiKey
        case .assemblyAI:
            assemblyAIApiKey
        }
        return TranscriptionProviderSettings(
            provider: transcriptionProvider,
            apiKey: apiKey.trimmed,
            automaticLanguageCandidates: automaticLanguageCandidates
        )
    }

    private let legacyEnhancementProvider: EnhancementProvider
    private let legacyOpenRouterModel: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        apiKey = ""
        transcriptionProvider = defaults.string(forKey: Self.transcriptionProviderKey)
            .flatMap(TranscriptionProvider.init(rawValue:)) ?? .deepgram
        elevenLabsApiKey = ""
        museApiKey = ""
        assemblyAIApiKey = ""
        escToCancelRecording = (defaults.object(forKey: Self.escToCancelRecordingKey) as? Bool) ?? true
        playSoundEffects = (defaults.object(forKey: Self.playSoundEffectsKey) as? Bool) ?? false
        muteMediaDuringRecording = (defaults.object(forKey: Self.muteMediaDuringRecordingKey) as? Bool) ?? false
        restoreClipboardAfterPaste = (defaults.object(forKey: Self.restoreClipboardAfterPasteKey) as? Bool) ?? false
        showSelectedLanguageInMenuBar = (defaults.object(forKey: Self.showSelectedLanguageInMenuBarKey) as? Bool) ?? false
        showLanguageInRecorderWidget = (defaults.object(forKey: Self.showLanguageInRecorderWidgetKey) as? Bool) ?? true
        showLiveTranscriptInRecorderWidget = (defaults.object(forKey: Self.showLiveTranscriptInRecorderWidgetKey) as? Bool) ?? true

        let savedPosition = defaults.string(forKey: Self.overlayPositionKey)
        overlayPosition = savedPosition.flatMap(OverlayPosition.init(rawValue:)) ?? .top

        audioInputSelection = AudioInputSelection(
            storedValue: defaults.string(forKey: Self.audioInputSelectionKey)
        )

        let savedLanguage = defaults.string(forKey: Self.deepgramLanguageKey)
        deepgramLanguage = savedLanguage.flatMap(DeepgramLanguage.init(rawValue:)) ?? .automatic
        let savedAutomaticLanguageCandidates = defaults.stringArray(forKey: Self.automaticLanguageCandidatesKey)?
            .compactMap(DeepgramLanguage.init(rawValue:))
        automaticLanguageCandidates = TranscriptionProvider.elevenLabs.normalizedAutomaticLanguageCandidates(
            savedAutomaticLanguageCandidates
                ?? TranscriptionProvider.elevenLabs.defaultAutomaticLanguageCandidates
        )
        starredDeepgramLanguages = DeepgramLanguage.starredLanguages(
            from: defaults.stringArray(forKey: Self.starredDeepgramLanguagesKey)
        )

        let savedLimit = defaults.object(forKey: Self.historyLimitKey) as? Int
        historyLimit = savedLimit.flatMap(DictationHistoryLimit.init(rawValue:)) ?? .ten

        if let data = defaults.data(forKey: Self.appTranscriptionLanguageOverridesKey),
           let decoded = try? JSONDecoder().decode([AppTranscriptionLanguageOverride].self, from: data) {
            appTranscriptionLanguageOverrides = decoded
        } else {
            appTranscriptionLanguageOverrides = []
        }

        if let data = defaults.data(forKey: Self.shortcutsKey),
           let decoded = try? JSONDecoder().decode([ShortcutConfig].self, from: data),
           !decoded.isEmpty {
            shortcuts = decoded
        } else {
            shortcuts = [ShortcutConfig.makeDefault()]
        }

        legacyEnhancementProvider = defaults.string(forKey: Self.enhancementProviderKey)
            .flatMap(EnhancementProvider.init(rawValue:)) ?? .openRouter
        let savedOpenRouterModel = (defaults.string(forKey: Self.openRouterModelKey)?.trimmed)
            .flatMap { $0.isEmpty ? nil : $0 }
        legacyOpenRouterModel = savedOpenRouterModel ?? EnhancementProvider.openRouter.defaultModel
        openRouterApiKey = ""
        celerisApiKey = ""
        mercuryApiKey = ""

        if let data = defaults.data(forKey: Self.promptsKey),
           let decoded = try? JSONDecoder().decode([PromptConfig].self, from: data) {
            prompts = Self.migratedPromptConfigurations(
                decoded,
                encodedData: data,
                legacyProvider: legacyEnhancementProvider,
                legacyOpenRouterModel: legacyOpenRouterModel
            )
            if prompts != decoded,
               let migratedData = try? JSONEncoder().encode(prompts) {
                defaults.set(migratedData, forKey: Self.promptsKey)
            }
        } else {
            prompts = []
            PromptRoutingService.migrateLegacyEnhancementPromptsIfNeeded(
                defaults: defaults,
                shortcuts: &shortcuts,
                prompts: &prompts,
                provider: legacyEnhancementProvider,
                model: legacyModel(for: legacyEnhancementProvider)
            )
        }
    }

    private func legacyModel(for provider: EnhancementProvider) -> String {
        switch provider {
        case .openRouter: legacyOpenRouterModel
        case .celeris, .mercury: provider.defaultModel
        }
    }

    private static func migratedPromptConfigurations(
        _ prompts: [PromptConfig],
        encodedData: Data,
        legacyProvider: EnhancementProvider,
        legacyOpenRouterModel: String
    ) -> [PromptConfig] {
        guard let objects = try? JSONSerialization.jsonObject(with: encodedData) as? [[String: Any]],
              objects.count == prompts.count else {
            return prompts
        }

        return prompts.enumerated().map { index, prompt in
            var prompt = prompt
            let object = objects[index]
            if object["provider"] == nil {
                prompt.provider = legacyProvider
            }
            if object["model"] == nil {
                prompt.model = prompt.provider == .openRouter
                    ? legacyOpenRouterModel
                    : prompt.provider.defaultModel
            }
            return prompt
        }
    }
}
