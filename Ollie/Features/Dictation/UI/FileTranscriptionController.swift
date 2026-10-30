import Foundation
import Observation

@MainActor
@Observable
final class FileTranscriptionController {
    typealias Transcriber = @Sendable (URL, TranscriptionProviderSettings, DeepgramLanguage) async throws -> String

    private let session: DictationSessionState
    private let transcriber: Transcriber
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ownedDirectory: URL?
    @ObservationIgnored private var clearAfterFinishing = false
    private(set) var isTranscribing = false
    private(set) var isImporting = false
    private(set) var stagedFile: URL?
    private(set) var error: String?
    private(set) var result: TranscriptHistoryEntry?
    private(set) var activeProvider: TranscriptionProvider?
    var language: DeepgramLanguage
    var isBusy: Bool { isTranscribing || isImporting }
    var processingLabel: String { isImporting ? "Importing audio…" : "Transcribing…" }

    init(session: DictationSessionState, language: DeepgramLanguage = .automatic, transcriber: @escaping Transcriber) {
        self.session = session
        self.language = language
        self.transcriber = transcriber
    }

    func stage(_ fileURL: URL, ownedDirectory: URL? = nil) {
        guard !isBusy else { return }
        if stagedFile?.standardizedFileURL != fileURL.standardizedFileURL {
            discardOwnedFile()
            self.ownedDirectory = ownedDirectory
        } else if self.ownedDirectory == nil {
            self.ownedDirectory = ownedDirectory
        }
        stagedFile = fileURL
        result = nil
        error = nil
    }

    func clear() {
        guard !isBusy else { return }
        discardOwnedFile()
        stagedFile = nil
        result = nil
        error = nil
    }

    func reportError(_ message: String) {
        guard !isTranscribing else { return }
        error = message
    }

    func beginImport() -> Bool {
        guard !isBusy else { return false }
        isImporting = true
        error = nil
        return true
    }

    func finishImport() {
        isImporting = false
        clearIfStopped()
    }

    func stop() {
        task?.cancel()
        clearAfterFinishing = true
        clearIfStopped()
    }

    private func clearIfStopped() {
        guard clearAfterFinishing, !isBusy else { return }
        clearAfterFinishing = false
        clear()
    }

    private func discardOwnedFile() {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        ownedDirectory = nil
    }

    func start(
        settings: TranscriptionProviderSettings,
        historyLimit: @escaping () -> DictationHistoryLimit
    ) {
        guard !isBusy, let fileURL = stagedFile else { return }
        let language = settings.provider.normalizedLanguage(language)
        error = nil
        guard !settings.apiKey.trimmed.isEmpty else {
            error = "Add your \(settings.provider.displayName) API key in Dictation settings."
            return
        }
        isTranscribing = true
        activeProvider = settings.provider
        result = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                isTranscribing = false
                activeProvider = nil
                task = nil
                clearIfStopped()
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
