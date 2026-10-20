import Foundation

enum EnhancementProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openRouter
    case celeris
    case mercury

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .celeris: "Celeris"
        case .mercury: "Mercury"
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: "inception/mercury-2"
        case .celeris: CelerisClient.model
        case .mercury: MercuryClient.model
        }
    }
}

struct EnhancementProviderSettings: Sendable {
    let provider: EnhancementProvider
    let apiKey: String
    let model: String

    var missingCredential: String? {
        if apiKey.trimmed.isEmpty {
            return "API key"
        }
        if model.trimmed.isEmpty {
            return "model"
        }
        return nil
    }
}

enum EnhancementClient {
    static func enhance(
        transcript: String,
        prompt: String,
        settings: EnhancementProviderSettings
    ) async throws -> String {
        switch settings.provider {
        case .openRouter:
            return try await OpenRouterClient.enhance(
                transcript: transcript,
                prompt: prompt,
                apiKey: settings.apiKey,
                model: settings.model
            )
        case .celeris:
            return try await CelerisClient.enhance(
                transcript: transcript,
                prompt: prompt,
                apiKey: settings.apiKey,
                model: settings.model
            )
        case .mercury:
            return try await MercuryClient.enhance(
                transcript: transcript,
                prompt: prompt,
                apiKey: settings.apiKey,
                model: settings.model
            )
        }
    }
}
