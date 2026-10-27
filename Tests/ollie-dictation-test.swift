import AppKit
import Foundation

func assertEqual<T: Equatable>(_ first: T, _ second: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(first == second, "\(message): \(first) != \(second)", file: file, line: line) }
func assertTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(value, message, file: file, line: line) }
func assertFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(!value, message, file: file, line: line) }
func assertNil<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { precondition(value == nil, message, file: file, line: line) }
func testFailure(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw NSError(domain: "test", code: 1) }; return value }

private final class HistoryFixture: TranscriptHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [TranscriptHistoryEntry] = []
    private var shouldFail = true
    private var writes = 0
    var entries: [TranscriptHistoryEntry] { lock.withLock { saved } }
    var attempts: Int { lock.withLock { writes } }
    func saveEntries(_ entries: [TranscriptHistoryEntry]) throws {
        try lock.withLock {
            writes += 1
            if shouldFail { shouldFail = false; throw CocoaError(.fileWriteOutOfSpace) }
            saved = entries
        }
    }
}

@main @MainActor struct OllieDictationTests {
    static func main() async throws {
        try mercuryRequests()
        await PasteRuntimeTests().testHandOffPreservesHistoryWithoutTouchingClipboard()
        await RecordingRuntimeTests().testUnenhancedRecordingReportsEveryAbandonedExit()
        await RecordingRuntimeTests().testTimedSpeechUsesAudioTimeAndWaitsThroughFinalization()
        await RecordingRuntimeTests().testReconnectsOnceThenStopsRetryingAndFinalizes()
        await RecordingRuntimeTests().testDoesNotReconnectWhileFinalizing()
        await RecordingRuntimeTests().testProviderErrorIsPreservedWhenConnectionThenDrops()
        await RecordingRuntimeTests().testCancelFromEscWhileFinalizingStopsSessionWithoutFinalizing()
        await RecordingRuntimeTests().testDiscardSilentlyStopsProvisionalRecording()
        await RecordingRuntimeTests().testFinalizeIncludesSavedRawRecordingAndLanguage()
        await RecordingRuntimeTests().testChangingLanguageWhileRecordingReconnectsAndFinalizesWithNewLanguage()
        await RecordingRuntimeTests().testRoutesOneConvertedChunkToRawCaptureAndTranscriptionStream()
        await RecordingRuntimeTests().testCancelDuringPendingCaptureStartCannotOpenAStaleSession()
        await PasteRuntimeTests().testPasteKeepsClipboardByDefaultAfterAutoPaste()
        await PasteRuntimeTests().testPasteRestoresClipboardOnlyAfterConfirmedAutoPaste()
        await PasteRuntimeTests().testEnhancementMissingCredentialsFallsBackToOriginalAndRecordsError()
        await PasteRuntimeTests().testCancellationDuringEnhancementSkipsPasteAndEmitsCancelled()
        await PasteRuntimeTests().testRestoreEnabledKeepsClipboardWhenVerificationCannotPrepare()
        await PasteRuntimeTests().testRestoreEnabledKeepsClipboardWhenVerificationMismatches()
        await PasteRuntimeTests().testRestoreEnabledKeepsClipboardWhenVerificationTimesOut()
        await PasteRuntimeTests().testPasteCommandFailureDoesNotRestoreClipboardEvenWhenEnabled()
        ShortcutRuntimeTests().testSuperCapsLockCyclesOncePerPressOnlyWhileRecording()
        ShortcutRuntimeTests().testCompanionKeyDiscardsRecordingWhileShortcutIsHeldWithoutConsumingKey()
        ShortcutRuntimeTests().testFnKeyDownDoesNotDiscardItsOwnQuickPress()
        await PasteRuntimeTests().testNewCopyAndStopCancelPendingRestoration()
        diagnosticLogging()
        try await historyPersistence()
        print("PASS: dictation runtime, awaited shutdown, clipboard ownership and history retry scenarios")
    }

    private static func mercuryRequests() throws {
        let request = try MercuryClient.makeRequest(
            transcript: "hello there", prompt: "Fix punctuation.", apiKey: "test-key",
            model: EnhancementProvider.mercury.defaultModel
        )
        assertEqual(request.url?.absoluteString, "https://api.inceptionlabs.ai/v1/chat/completions")
        assertEqual(request.httpMethod, "POST")
        assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try unwrap(JSONSerialization.jsonObject(with: unwrap(request.httpBody)) as? [String: Any])
        assertEqual(body["model"] as? String, "mercury-3")
        assertEqual(body["reasoning_effort"] as? String, "instant")
        let messages = try unwrap(body["messages"] as? [[String: String]])
        assertEqual(messages, [["role": "user", "content": "Fix punctuation.\n\n<transcription>hello there</transcription>"]])
        let response = Data(#"{"choices":[{"message":{"content":"Hello there.","reasoning_content":"private reasoning"}}]}"#.utf8)
        assertEqual(try MercuryClient.content(from: response), "Hello there.")
        for response in [
            #"{"choices":[]}"#,
            #"{"choices":[{"message":{"content":null}}]}"#,
            #"{"choices":[{"message":{"content":" "}}]}"#
        ] {
            do {
                _ = try MercuryClient.content(from: Data(response.utf8))
                testFailure("Empty Mercury output must fail")
            } catch MercuryError.noContent {
            }
        }
        let prompt = PromptConfig.makeDefault(provider: .mercury)
        let restored = try JSONDecoder().decode(PromptConfig.self, from: JSONEncoder().encode(prompt))
        assertEqual(restored.provider, .mercury)
        assertEqual(restored.model, "mercury-3")
    }

    private static func diagnosticLogging() {
        var enabled = false
        let state = DictationSessionState(diagnosticsEnabled: { enabled })
        state.addLog("detail")
        assertTrue(state.logs.isEmpty)
        state.addLog("warning", level: .warning)
        state.addLog("error", level: .error)
        assertEqual(state.logs.map(\.message), ["warning", "error"])
        enabled = true
        state.addLog("enabled")
        enabled = false
        state.addLog("disabled")
        assertEqual(state.logs.map(\.message), ["warning", "error", "enabled"])
    }

    private static func historyPersistence() async throws {
        let storage = HistoryFixture()
        var results: [TranscriptHistoryWriteResult] = []
        let writer = TranscriptHistoryWriter(store: storage) { results.append($0) }
        let entry = TranscriptHistoryEntry(timestamp: Date(), text: "newest")
        writer.submit([entry], revision: 1)
        let result = await writer.flush()
        assertEqual(result?.revision, 1)
        assertNil(result?.errorMessage)
        assertEqual(storage.attempts, 2)
        assertEqual(storage.entries.first?.text, "newest")
        assertTrue(results.first?.errorMessage != nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let original = Data("corrupted history".utf8)
        try original.write(to: file)
        let store = TranscriptHistoryStore(fileURL: file)
        let state = DictationSessionState(historyStore: store, initialHistoryIsPersisted: false)
        state.reportHistoryLoadFailure()
        state.storeTranscriptHistoryEntry(entry, limit: .hundred)
        assertFalse(await state.flushHistory())
        assertEqual(try Data(contentsOf: file), original)
    }
}
