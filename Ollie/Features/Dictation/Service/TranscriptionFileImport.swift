import AppKit
import Synchronization

struct ReceivedAudioFile {
    let url: URL
    let ownedDirectory: URL?

    func discard() {
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}

@MainActor
enum TranscriptionFileImport {
    case file(URL)
    case promise(NSFilePromiseReceiver)

    static let draggedTypes = [NSPasteboard.PasteboardType.fileURL]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: draggedTypes) != nil
    }

    static func read(_ pasteboard: NSPasteboard) -> Self? {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
        if let receiver = receivers?.first {
            return .promise(receiver)
        }
        return PasteboardFiles.urls(on: pasteboard, limit: 1, matching: { _ in true }).first.map(Self.file)
    }

    func receive(in root: URL) async throws -> ReceivedAudioFile {
        try Task.checkCancellation()
        switch self {
        case .file(let url): return ReceivedAudioFile(url: url, ownedDirectory: nil)
        case .promise(let receiver):
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            do {
                let url = try await Self.receive(receiver, into: directory)
                try Task.checkCancellation()
                guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
                    throw AudioFileError.notAudio
                }
                try TranscriptionAudioFile.validate(url)
                return ReceivedAudioFile(url: url, ownedDirectory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }

    private enum Delivery: Sendable { case pending, delivered, abandoned }

    private static func receive(_ receiver: NSFilePromiseReceiver, into directory: URL) async throws -> URL {
        let delivery = Mutex(Delivery.pending)
        let (stream, continuation) = AsyncThrowingStream<URL, any Error>.makeStream()
        let abandon: @Sendable (any Error) -> Void = { error in
            delivery.withLock { state in
                guard case .pending = state else { return }
                state = .abandoned
                continuation.finish(throwing: error)
            }
        }
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) { url, error in
            delivery.withLock { state in
                switch state {
                case .pending:
                    if let error {
                        state = .abandoned
                        continuation.finish(throwing: error)
                    } else {
                        state = .delivered
                        continuation.yield(url)
                        continuation.finish()
                    }
                case .abandoned:
                    try? FileManager.default.removeItem(at: directory)
                case .delivered: break
                }
            }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            abandon(URLError(.timedOut))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            for try await url in stream {
                try Task.checkCancellation()
                return url
            }
            throw CancellationError()
        } onCancel: {
            abandon(CancellationError())
        }
    }
}
