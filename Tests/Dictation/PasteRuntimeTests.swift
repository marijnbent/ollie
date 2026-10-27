import Foundation

@MainActor
final class PasteRuntimeTests {
    func testHandOffPreservesHistoryWithoutTouchingClipboard() async {
        let clock = ManualClock()
        let pasteboard = FakePasteboardPort()
        let verification = FakePasteVerificationPort()
        let runtime = PasteRuntime(pasteboard: pasteboard, pasteVerification: verification,
                                   scheduler: ManualScheduler(clock: clock), enhancer: { _, _, _ in "" })
        var events: [PasteRuntimeEvent] = []
        runtime.onEvent = { events.append($0) }
        let outcome = await runtime.process(
            session: FinalizedTranscriptSession(finalTranscript: "The button is clipped.", lastTranscript: "",
                                                enhancementPrompt: nil, transcriptionError: nil),
            settings: PasteRuntimeSettings(enhancement: nil, playSoundEffects: false,
                                            restoreClipboardAfterPaste: true, delivery: .handOff))
        assertEqual(outcome.text, "The button is clipped.")
        assertTrue(outcome.recordingAdopted)
        assertEqual(events.compactMap(historyEntry).first?.text, "The button is clipped.")
        assertEqual(pasteboard.snapshotCallCount, 0)
        assertTrue(pasteboard.writtenStrings.isEmpty && pasteboard.restoredSnapshots.isEmpty)
        assertEqual(pasteboard.sendPasteCommandCallCount, 0)
        assertEqual(verification.prepareCallCount, 0)
    }

    func testPasteKeepsClipboardByDefaultAfterAutoPaste() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        let pasteVerification = FakePasteVerificationPort()

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        var events: [PasteRuntimeEvent] = []
        runtime.onEvent = { events.append($0) }

        let recordingAdopted = await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: false
            )
        )

        assertTrue(recordingAdopted.recordingAdopted)
        assertEqual(pasteboard.writtenStrings.last, "hello world")
        assertEqual(pasteboard.sendPasteCommandCallCount, 1)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertEqual(pasteVerification.prepareCallCount, 0)
        assertEqual(pasteVerification.checkCallCount, 0)

        scheduler.advance(by: 0.5)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertTrue(events.contains(where: matchesIdleStatus))
    }

    func testPasteRestoresClipboardOnlyAfterConfirmedAutoPaste() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        let pasteVerification = FakePasteVerificationPort()
        pasteVerification.prepareResult = makePreparedPasteVerification(expectedText: "hello world")
        pasteVerification.checkResults = [.pending, .confirmed]

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: true
            )
        )

        assertEqual(pasteboard.writtenStrings.last, "hello world")
        assertEqual(pasteboard.sendPasteCommandCallCount, 1)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertEqual(pasteVerification.prepareCallCount, 1)
        assertEqual(pasteVerification.checkCallCount, 0)

        scheduler.advance(by: 0.051)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertEqual(pasteVerification.checkCallCount, 1)

        scheduler.advance(by: 0.051)
        assertEqual(pasteboard.restoredSnapshots.count, 1)
        assertEqual(pasteboard.restoredSnapshots[0], pasteboard.currentSnapshot)
        assertEqual(pasteVerification.checkCallCount, 2)
    }

    func testNewCopyAndStopCancelPendingRestoration() async {
        for copiedAfterPaste in [false, true] {
            let clock = ManualClock()
            let scheduler = ManualScheduler(clock: clock)
            let pasteboard = FakePasteboardPort()
            let verification = FakePasteVerificationPort()
            verification.prepareResult = makePreparedPasteVerification(expectedText: "hello")
            verification.checkResults = [.confirmed]
            let runtime = PasteRuntime(pasteboard: pasteboard, pasteVerification: verification, scheduler: scheduler, enhancer: { _, _, _ in "" })
            await runtime.process(session: FinalizedTranscriptSession(finalTranscript: "hello", lastTranscript: "", enhancementPrompt: nil, transcriptionError: nil),
                settings: PasteRuntimeSettings(enhancement: nil, playSoundEffects: false, restoreClipboardAfterPaste: true))
            if copiedAfterPaste { pasteboard.changeToken += 1 }
            else { runtime.cancelPendingVerification() }
            scheduler.advance(by: 0.5)
            assertTrue(pasteboard.restoredSnapshots.isEmpty)
            assertEqual(verification.checkCallCount, 0)
        }
    }

    func testEnhancementMissingCredentialsFallsBackToOriginalAndRecordsError() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        let pasteVerification = FakePasteVerificationPort()
        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in
                testFailure("Enhancer should not be called when credentials are missing")
                return ""
            }
        )

        var emittedEvents: [PasteRuntimeEvent] = []
        runtime.onEvent = { emittedEvents.append($0) }

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "raw transcript",
                lastTranscript: "",
                enhancementPrompt: EnhancementPromptContext(
                    name: "Clean",
                    content: "clean this",
                    isForActiveApp: false
                ),
                transcriptionError: nil,
                rawRecordingFileURL: URL(fileURLWithPath: "/tmp/raw.wav"),
                transcriptionLanguage: .english
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: false
            )
        )

        assertEqual(pasteboard.writtenStrings.last, "raw transcript")

        let historyEntry = emittedEvents.compactMap(historyEntry).first
        assertEqual(historyEntry?.enhancementError, "Celeris API key is not set.")
        assertEqual(historyEntry?.promptName, "Clean")
        assertEqual(historyEntry?.enhancementPromptText, "clean this")
        assertEqual(historyEntry?.rawRecordingFileURL, URL(fileURLWithPath: "/tmp/raw.wav"))
        assertEqual(historyEntry?.transcriptionLanguage, .english)
        assertEqual(historyEntry?.usedActiveAppPrompt, false)
        assertTrue(emittedEvents.contains(where: matchesIdleStatus))
    }

    func testCancellationDuringEnhancementSkipsPasteAndEmitsCancelled() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        let pasteVerification = FakePasteVerificationPort()
        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
        )

        var emittedEvents: [PasteRuntimeEvent] = []
        runtime.onEvent = { emittedEvents.append($0) }

        let task = Task {
            await runtime.process(
                session: FinalizedTranscriptSession(
                    finalTranscript: "raw transcript",
                    lastTranscript: "",
                    enhancementPrompt: EnhancementPromptContext(
                        name: "Clean",
                        content: "clean this",
                        isForActiveApp: false
                    ),
                    transcriptionError: nil
                ),
                settings: PasteRuntimeSettings(
                    enhancement: celerisSettings(apiKey: "ck-test"),
                    playSoundEffects: false,
                    restoreClipboardAfterPaste: false
                )
            )
        }

        await Task.yield()
        task.cancel()
        let recordingAdopted = await task.value
        assertTrue(!recordingAdopted.recordingAdopted)

        assertTrue(pasteboard.writtenStrings.isEmpty)
        assertEqual(pasteboard.sendPasteCommandCallCount, 0)
        assertTrue(emittedEvents.contains(where: matchesCancelledStatus))
        assertTrue(emittedEvents.contains(where: isHideOverlayEvent))
    }

    func testRestoreEnabledKeepsClipboardWhenVerificationCannotPrepare() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        let pasteVerification = FakePasteVerificationPort()

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        var emittedEvents: [PasteRuntimeEvent] = []
        runtime.onEvent = { emittedEvents.append($0) }

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: true
            )
        )

        assertEqual(pasteVerification.prepareCallCount, 1)
        assertEqual(pasteVerification.checkCallCount, 0)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertTrue(emittedEvents.contains(where: matchesClipboardKeptLog))

        scheduler.advance(by: 0.5)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
    }

    func testRestoreEnabledKeepsClipboardWhenVerificationMismatches() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        let pasteVerification = FakePasteVerificationPort()
        pasteVerification.prepareResult = makePreparedPasteVerification(expectedText: "hello world")
        pasteVerification.checkResults = [.unconfirmed(.mismatch)]

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        var emittedEvents: [PasteRuntimeEvent] = []
        runtime.onEvent = { emittedEvents.append($0) }

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: true
            )
        )

        scheduler.advance(by: 0.051)

        assertEqual(pasteVerification.prepareCallCount, 1)
        assertEqual(pasteVerification.checkCallCount, 1)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertTrue(emittedEvents.contains(where: matchesClipboardKeptLog))
    }

    func testRestoreEnabledKeepsClipboardWhenVerificationTimesOut() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        let pasteVerification = FakePasteVerificationPort()
        pasteVerification.prepareResult = makePreparedPasteVerification(expectedText: "hello world")

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        var emittedEvents: [PasteRuntimeEvent] = []
        runtime.onEvent = { emittedEvents.append($0) }

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: true
            )
        )

        for _ in 0..<7 {
            scheduler.advance(by: 0.051)
        }

        assertEqual(pasteVerification.prepareCallCount, 1)
        assertEqual(pasteVerification.checkCallCount, 7)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertTrue(emittedEvents.contains(where: matchesClipboardKeptLog))
    }

    func testPasteCommandFailureDoesNotRestoreClipboardEvenWhenEnabled() async {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let pasteboard = FakePasteboardPort()
        pasteboard.currentSnapshot = PasteboardSnapshotPayload(
            items: [["public.utf8-plain-text": Data("old".utf8)]]
        )
        pasteboard.sendPasteCommandResult = false
        let pasteVerification = FakePasteVerificationPort()
        pasteVerification.prepareResult = makePreparedPasteVerification(expectedText: "hello world")

        let runtime = PasteRuntime(
            pasteboard: pasteboard,
            pasteVerification: pasteVerification,
            scheduler: scheduler,
            enhancer: { _, _, _ in "" }
        )

        await runtime.process(
            session: FinalizedTranscriptSession(
                finalTranscript: "hello world",
                lastTranscript: "",
                enhancementPrompt: nil,
                transcriptionError: nil
            ),
            settings: PasteRuntimeSettings(
                enhancement: celerisSettings(),
                playSoundEffects: false,
                restoreClipboardAfterPaste: true
            )
        )

        assertEqual(pasteboard.writtenStrings.last, "hello world")
        assertEqual(pasteboard.sendPasteCommandCallCount, 1)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
        assertEqual(pasteVerification.prepareCallCount, 1)
        assertEqual(pasteVerification.checkCallCount, 0)

        scheduler.advance(by: 0.5)
        assertTrue(pasteboard.restoredSnapshots.isEmpty)
    }

    private func historyEntry(from event: PasteRuntimeEvent) -> TranscriptHistoryEntry? {
        if case .historyEntry(let entry) = event {
            return entry
        }
        return nil
    }

    private func celerisSettings(apiKey: String = "") -> EnhancementProviderSettings {
        EnhancementProviderSettings(provider: .celeris, apiKey: apiKey, model: EnhancementProvider.celeris.defaultModel)
    }

    private func matchesIdleStatus(_ event: PasteRuntimeEvent) -> Bool {
        if case .status(.idle) = event {
            return true
        }
        return false
    }

    private func matchesCancelledStatus(_ event: PasteRuntimeEvent) -> Bool {
        if case .status(.cancelled) = event {
            return true
        }
        return false
    }

    private func isHideOverlayEvent(_ event: PasteRuntimeEvent) -> Bool {
        if case .hideOverlay = event {
            return true
        }
        return false
    }

    private func matchesClipboardKeptLog(_ event: PasteRuntimeEvent) -> Bool {
        if case .log("Could not confirm auto-paste. Kept transcript on the clipboard.", .warning) = event {
            return true
        }
        return false
    }
}
