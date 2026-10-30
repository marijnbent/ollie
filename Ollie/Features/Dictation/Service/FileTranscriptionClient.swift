import Foundation

enum FileTranscriptionClient {
    nonisolated static func transcribe(
        fileURL: URL,
        settings: TranscriptionProviderSettings,
        language: DeepgramLanguage
    ) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let audio = directory.appendingPathComponent("recording.wav")
            try await TranscriptionAudioFile.prepare(source: fileURL, destination: audio)
            try Task.checkCancellation()
            return try await PrerecordedTranscriptionClient.transcribe(fileURL: audio, settings: settings, language: language)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
