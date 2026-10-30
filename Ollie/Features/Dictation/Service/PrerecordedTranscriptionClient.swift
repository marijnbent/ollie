import Foundation

enum PrerecordedTranscriptionClient {
    static func transcribe(
        fileURL: URL,
        settings: TranscriptionProviderSettings,
        language: DeepgramLanguage
    ) async throws -> String {
        let normalizedLanguage = settings.provider.normalizedLanguage(language)
        switch settings.provider {
        case .deepgram:
            return try await DeepgramPrerecordedClient.transcribe(
                fileURL: fileURL,
                apiKey: settings.apiKey,
                language: normalizedLanguage
            )
        case .elevenLabs:
            return try await ElevenLabsPrerecordedClient.transcribe(
                fileURL: fileURL,
                apiKey: settings.apiKey,
                language: normalizedLanguage
            )
        case .assemblyAI:
            let session = DictationHTTP.session()
            defer { session.invalidateAndCancel() }
            return try await AssemblyAIPrerecordedClient.transcribe(
                fileURL: fileURL,
                apiKey: settings.apiKey,
                language: normalizedLanguage,
                automaticLanguageCandidates: settings.automaticLanguageCandidates,
                session: session
            )
        case .muse:
            return try await MusePrerecordedClient.transcribe(
                fileURL: fileURL,
                apiKey: settings.apiKey,
                language: normalizedLanguage,
                automaticLanguageCandidates: settings.automaticLanguageCandidates
            )
        }
    }
}
