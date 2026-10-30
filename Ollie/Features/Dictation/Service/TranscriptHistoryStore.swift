import Foundation

protocol TranscriptHistoryPersisting: AnyObject, Sendable {
    func saveEntries(_ entries: [TranscriptHistoryEntry]) throws
}

final class TranscriptHistoryStore: TranscriptHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadEntries() throws -> [TranscriptHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let data = try Data(contentsOf: fileURL)
        let entries = try decoder.decode([TranscriptHistoryEntry].self, from: data)
        return entries.map { entry in
            guard let rawRecordingFileURL = entry.rawRecordingFileURL else { return entry }
            guard fileManager.fileExists(atPath: rawRecordingFileURL.path) else {
                return TranscriptHistoryEntry(
                    id: entry.id,
                    timestamp: entry.timestamp,
                    text: entry.text,
                    enhancedText: entry.enhancedText,
                    transcriptionError: entry.transcriptionError,
                    enhancementError: entry.enhancementError,
                    promptName: entry.promptName,
                    enhancementPromptText: entry.enhancementPromptText,
                    enhancementProvider: entry.enhancementProvider,
                    enhancementModel: entry.enhancementModel,
                    rawRecordingFileURL: nil,
                    transcriptionLanguage: entry.transcriptionLanguage,
                    usedActiveAppPrompt: entry.usedActiveAppPrompt,
                    sourceFileName: entry.sourceFileName
                )
            }

            return entry
        }
    }

    func saveEntries(_ entries: [TranscriptHistoryEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        AppPaths.applicationSupport().appendingPathComponent("Dictation/transcript-history.json")
    }
}

struct TranscriptHistoryWriteResult: Sendable {
    let revision: Int
    let sequence: Int
    let errorMessage: String?
}

@MainActor
final class TranscriptHistoryWriter {
    private struct Snapshot: Sendable {
        let revision: Int
        let entries: [TranscriptHistoryEntry]
    }
    private let store: any TranscriptHistoryPersisting
    private let completion: @MainActor (TranscriptHistoryWriteResult) -> Void
    private var latestSnapshot: Snapshot?
    private var pendingSnapshot: Snapshot?
    private var task: Task<Void, Never>?
    private var lastResult: TranscriptHistoryWriteResult?
    private var sequence = 0

    init(store: any TranscriptHistoryPersisting, completion: @escaping @MainActor (TranscriptHistoryWriteResult) -> Void) {
        self.store = store
        self.completion = completion
    }

    func submit(_ entries: [TranscriptHistoryEntry], revision: Int) {
        let snapshot = Snapshot(revision: revision, entries: entries)
        latestSnapshot = snapshot
        pendingSnapshot = snapshot
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while let snapshot = pendingSnapshot {
                pendingSnapshot = nil
                let failure = await Task.detached(priority: .utility) { [store] in
                    do { try store.saveEntries(snapshot.entries); return nil as String? }
                    catch { return error.localizedDescription }
                }.value
                sequence += 1
                let result = TranscriptHistoryWriteResult(revision: snapshot.revision, sequence: sequence, errorMessage: failure)
                lastResult = result
                completion(result)
            }
        }
    }

    func flush() async -> TranscriptHistoryWriteResult? {
        await task?.value
        if let latestSnapshot,
           lastResult?.revision != latestSnapshot.revision || lastResult?.errorMessage != nil {
            submit(latestSnapshot.entries, revision: latestSnapshot.revision)
            await task?.value
        }
        return lastResult
    }
}
