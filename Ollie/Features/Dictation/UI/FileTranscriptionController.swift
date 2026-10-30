import Foundation
import Observation

@MainActor
@Observable
final class FileTranscriptionController {
    typealias Transcriber = @Sendable (URL, TranscriptionProviderSettings, DeepgramLanguage) async throws -> String

    private let session: DictationSessionState
    private let transcriber: Transcriber
    @ObservationIgnored private var task: Task<Void, Never>?
    private(set) var isTranscribing = false
    private(set) var fileName: String?
    private(set) var error: String?
    private(set) var result: TranscriptHistoryEntry?

    init(session: DictationSessionState, transcriber: @escaping Transcriber) {
        self.session = session
        self.transcriber = transcriber
    }

    func start(
        fileURL: URL, settings: TranscriptionProviderSettings, language: DeepgramLanguage,
        historyLimit: @escaping () -> DictationHistoryLimit
    ) {
        guard !isTranscribing else { return }
        error = nil
        guard !settings.apiKey.trimmed.isEmpty else {
            error = "Add your \(settings.provider.displayName) API key in Recording first."
            return
        }
        isTranscribing = true
        fileName = fileURL.lastPathComponent
        result = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                isTranscribing = false
                task = nil
            }
            do {
                let text = try await transcriber(fileURL, settings, language).trimmed
                try Task.checkCancellation()
                guard !text.isEmpty else { throw AudioFileError.noTranscript }
                let entry = TranscriptHistoryEntry(
                    timestamp: Date(), text: text,
                    transcriptionLanguage: language, sourceFileName: fileURL.lastPathComponent
                )
                result = entry
                session.storeTranscriptHistoryEntry(entry, limit: historyLimit())
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func finish() async { await task?.value }
}
