import Foundation

enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepgram
    case elevenLabs
    case muse
    case assemblyAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepgram:
            return "Deepgram"
        case .elevenLabs:
            return "ElevenLabs"
        case .assemblyAI:
            return "AssemblyAI"
        case .muse:
            return "Muse"
        }
    }

    var languageOptions: [DeepgramLanguage] {
        switch self {
        case .deepgram:
            DeepgramLanguage.deepgramNova3Languages
        case .elevenLabs:
            DeepgramLanguage.elevenLabsLanguages
        case .assemblyAI:
            [.automatic, .afrikaans, .arabic, .cantonese, .catalan, .danish, .dutch, .english, .estonian, .finnish, .french, .galician, .german, .hebrew, .hindi, .italian, .japanese, .korean, .mandarinChinese, .marathi, .norwegian, .persian, .portuguese, .romanian, .russian, .spanish, .swedish, .turkish, .urdu, .vietnamese, .xhosa, .zulu]
        case .muse:
            DeepgramLanguage.museLanguages
        }
    }

    var supportsAutomaticLanguageCandidates: Bool {
        switch self {
        case .deepgram:
            false
        case .elevenLabs, .muse, .assemblyAI:
            true
        }
    }

    var automaticLanguageCandidateOptions: [DeepgramLanguage] {
        guard supportsAutomaticLanguageCandidates else { return [] }
        return languageOptions.filter { $0 != .automatic }
    }

    var defaultAutomaticLanguageCandidates: [DeepgramLanguage] {
        switch self {
        case .deepgram:
            []
        case .elevenLabs, .muse, .assemblyAI:
            [.dutch, .english]
        }
    }

    func normalizedAutomaticLanguageCandidates(_ candidates: [DeepgramLanguage]) -> [DeepgramLanguage] {
        guard supportsAutomaticLanguageCandidates else { return [] }

        let selected = Set(candidates)
        let normalized = automaticLanguageCandidateOptions.filter(selected.contains)
        return normalized.isEmpty ? defaultAutomaticLanguageCandidates : normalized
    }

    var automaticLanguageHelpText: String {
        switch self {
        case .deepgram:
            return "Automatic uses Deepgram's multilingual streaming model; custom language limits are not available."
        case .elevenLabs, .muse:
            return "Automatic uses the selected languages only."
        case .assemblyAI:
            return "Automatic favors the selected languages and allows language switching."
        }
    }

    func normalizedLanguage(_ language: DeepgramLanguage) -> DeepgramLanguage {
        switch self {
        case .deepgram:
            if languageOptions.contains(language) {
                return language
            }

            switch language {
            case .cantonese:
                return .chineseCantonese
            case .mandarinChinese:
                return .chineseMandarinSimplified
            case .filipino:
                return .tagalog
            default:
                return .automatic
            }
        case .elevenLabs, .assemblyAI:
            if languageOptions.contains(language) {
                return language
            }

            switch language {
            case .chineseCantonese:
                return .cantonese
            case .chineseMandarinSimplified,
                 .chineseMandarinSimplifiedChina,
                 .chineseMandarinSimplifiedHans,
                 .chineseMandarinTraditional,
                 .chineseMandarinTraditionalHant:
                return .mandarinChinese
            case .tagalog:
                return self == .assemblyAI ? .automatic : .filipino
            default:
                let baseCode = language.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
                return languageOptions.first(where: { $0.rawValue == baseCode }) ?? .automatic
            }
        case .muse:
            if languageOptions.contains(language) {
                return language
            }

            switch language {
            case .chineseCantonese,
                 .chineseMandarinSimplified,
                 .chineseMandarinSimplifiedChina,
                 .chineseMandarinSimplifiedHans,
                 .chineseMandarinTraditional,
                 .chineseMandarinTraditionalHant:
                return .mandarinChinese
            case .filipino:
                return .tagalog
            default:
                let baseCode = language.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
                return languageOptions.first(where: { $0.rawValue == baseCode }) ?? .automatic
            }
        }
    }
}

struct TranscriptionProviderSettings: Equatable, Sendable {
    var includeTimings = false
    let provider: TranscriptionProvider
    let apiKey: String
    let automaticLanguageCandidates: [DeepgramLanguage]

    init(
        provider: TranscriptionProvider,
        apiKey: String,
        automaticLanguageCandidates: [DeepgramLanguage]? = nil
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.automaticLanguageCandidates = provider.normalizedAutomaticLanguageCandidates(
            automaticLanguageCandidates ?? provider.defaultAutomaticLanguageCandidates
        )
    }
}
