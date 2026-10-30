import AppKit
import SwiftUI
import Synchronization

private final class SyntheticPromiseReceiver: NSFilePromiseReceiver {
    enum Behavior { case success, failure, waiting }
    let behavior: Behavior
    let started = Mutex(false)

    init(_ behavior: Behavior) {
        self.behavior = behavior
        super.init()
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) { fatalError() }

    override func receivePromisedFiles(
        atDestination destinationDir: URL, options: [AnyHashable: Any] = [:],
        operationQueue: OperationQueue, reader: @escaping (URL, (any Error)?) -> Void
    ) {
        started.withLock { $0 = true }
        guard behavior != .waiting else { return }
        let file = destinationDir.appendingPathComponent("Voice Memo.qta")
        do {
            try Data("synthetic recording".utf8).write(to: file)
            if behavior == .failure {
                reader(file, CocoaError(.fileReadCorruptFile))
            } else {
                reader(file, nil)
                reader(file, nil)
            }
        } catch { reader(file, error) }
    }
}

@MainActor
private final class SyntheticPromiseSource: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Voice Memo.qta" }
    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do { try Data("synthetic recording".utf8).write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

@MainActor
enum FileTranscriptionImportTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let providerDelegate = SyntheticPromiseSource()
        let provider = NSFilePromiseProvider(fileType: "com.apple.quicktime-audio", delegate: providerDelegate)
        assertTrue(board.writeObjects([provider]))
        assertTrue(TranscriptionFileImport.canRead(board))
        assertFalse(board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
        guard case .promise = TranscriptionFileImport.read(board) else {
            preconditionFailure("Native file promises must be recognized")
        }
        withExtendedLifetime((provider, providerDelegate)) {}

        let received = try await TranscriptionFileImport.promise(SyntheticPromiseReceiver(.success)).receive(in: root)
        assertTrue(FileManager.default.fileExists(atPath: received.url.path))
        let session = DictationSessionState()
        let controller = FileTranscriptionController(session: session) { _, _, _ in
            preconditionFailure("Receiving or pasting a recording must not transcribe it")
        }
        assertTrue(controller.beginImport())
        assertTrue(controller.isBusy)
        controller.finishImport()
        controller.stage(received.url, ownedDirectory: received.ownedDirectory)
        controller.stage(received.url)
        assertTrue(FileManager.default.fileExists(atPath: received.url.path))
        assertFalse(controller.isBusy)
        assertEqual(controller.stagedFile, received.url)
        assertTrue(session.transcriptHistory.isEmpty)
        controller.clear()
        assertFalse(FileManager.default.fileExists(atPath: received.ownedDirectory!.path))

        do {
            _ = try await TranscriptionFileImport.promise(SyntheticPromiseReceiver(.failure)).receive(in: root)
            testFailure("Failed export must not stage a file")
        } catch {}
        assertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let active = try await TranscriptionFileImport.promise(SyntheticPromiseReceiver(.success)).receive(in: root)
        let stopping = FileTranscriptionController(session: session) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return "Must not complete"
        }
        stopping.stage(active.url, ownedDirectory: active.ownedDirectory)
        stopping.start(settings: .init(provider: .elevenLabs, apiKey: "test-key"), historyLimit: { .none })
        stopping.stop()
        assertTrue(FileManager.default.fileExists(atPath: active.url.path))
        await stopping.finish()
        assertNil(stopping.stagedFile)
        assertFalse(FileManager.default.fileExists(atPath: active.url.path))

        let waiting = SyntheticPromiseReceiver(.waiting)
        let pending = Task { try await TranscriptionFileImport.promise(waiting).receive(in: root) }
        while !waiting.started.withLock({ $0 }) { await Task.yield() }
        pending.cancel()
        do {
            _ = try await pending.value
            testFailure("Cancelling a pending export must return")
        } catch is CancellationError {}
        assertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let original = root.appendingPathComponent("original.wav")
        try Data("original recording".utf8).write(to: original)
        PasteboardFiles.write(original, to: board)
        let fileSource = try unwrap(TranscriptionFileImport.read(board))
        let pasted = try await fileSource.receive(in: root)
        assertEqual(pasted.url, original)
        pasted.discard()
        assertTrue(FileManager.default.fileExists(atPath: original.path))
        controller.stage(original)
        controller.clear()
        assertTrue(FileManager.default.fileExists(atPath: original.path))
        var enabled = true
        var imports = 0
        let host = FileTranscriptionHostingView(
            rootView: EmptyView(), canImport: { enabled },
            receive: { pasteboard in
                assertTrue(pasteboard === board)
                imports += 1
                return true
            }, targeted: { _ in }, pasteboard: { board }
        )
        assertTrue(TranscriptionFileImport.draggedTypes.allSatisfy(host.registeredDraggedTypes.contains))
        let paste = try unwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        assertTrue(host.performKeyEquivalent(with: paste))
        assertEqual(imports, 1)
        host.paste(nil)
        assertEqual(imports, 2)
        enabled = false
        assertTrue(host.performKeyEquivalent(with: paste))
        host.paste(nil)
        assertEqual(imports, 2)
        board.clearContents()
        board.setString("Built-in transcript", forType: .string)
        assertFalse(TranscriptionFileImport.canRead(board))
        assertNil(TranscriptionFileImport.read(board))
    }
}
