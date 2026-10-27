import Foundation
import AppKit

@MainActor
final class RecordingRuntimeTests {
    private struct RuntimeHarness {
        let runtime: RecordingRuntime
        let audio: FakeAudioCapturePort
        let deepgram: FakeTranscriptionStreamPort
        let scheduler: ManualScheduler
        let statuses: Box<[AppStatus]>
        let finalizations: Box<[RecordingFinalization]>
        let rawRecordingCapture: FakeRawRecordingCapture
    }

    func testUnenhancedRecordingReportsEveryAbandonedExit() async {
        for exit in ["cancel", "discard", "start failure", "input change", "finalize"] {
            var promptCalls = 0
            let harness = makeHarness(resolvedEnhancementPromptProvider: { _, _ in
                promptCalls += 1
                return EnhancementPromptContext(name: "Email", content: "Rewrite as a formal email.", isForActiveApp: true)
            })
            var abandoned = 0
            harness.runtime.onAbandoned = { abandoned += 1 }
            harness.audio.shouldFailStart = exit == "start failure"
            harness.runtime.startUnenhanced(ownerShortcutID: UUID())
            if exit == "start failure" {
                await waitUntil { abandoned == 1 }
            } else {
                await waitUntil { harness.deepgram.connectCalls.count == 1 }
                switch exit {
                case "cancel": harness.runtime.cancelFromEsc()
                case "discard": harness.runtime.handle(action: .discard)
                case "input change":
                    harness.audio.emitConfigurationChange()
                    await waitUntil { abandoned == 1 }
                default:
                    harness.runtime.handle(action: .stop)
                    await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
                    harness.deepgram.completeClose()
                    await waitUntil { harness.finalizations.value.count == 1 }
                    assertNil(harness.finalizations.value.first?.enhancementPrompt)
                }
            }
            assertEqual(abandoned, exit == "finalize" ? 0 : 1, exit)
            assertEqual(promptCalls, 0)
            await harness.runtime.waitForShutdown()
        }
    }

    func testTimedSpeechUsesAudioTimeAndWaitsThroughFinalization() async {
        let harness = makeHarness()
        harness.scheduler.advance(by: 100)
        harness.runtime.startUnenhanced(ownerShortcutID: UUID())
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        assertTrue(harness.deepgram.connectCalls[0].includeTimings)
        harness.scheduler.advance(by: 10)
        harness.deepgram.onTimedTranscript?([TranscriptSpan(text: "First screen", start: 2, end: 3)])
        await Task.yield()
        harness.deepgram.emitConnectionDropped("Reconnect")
        await Task.yield()
        harness.scheduler.advance(by: 0.4)
        await waitUntil { harness.deepgram.connectCalls.count == 2 }
        harness.runtime.handle(action: .stop)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
        harness.deepgram.onTimedTranscript?([TranscriptSpan(text: "Second screen", start: 0.2, end: 0.8)])
        await Task.yield()
        harness.deepgram.completeClose()
        await waitUntil { harness.finalizations.value.count == 1 }
        let spans = harness.finalizations.value[0].transcriptSpans
        assertEqual(spans.count, 2)
        assertEqual(spans[0], TranscriptSpan(text: "First screen", start: 102, end: 103))
        assertTrue(abs(spans[1].start - 110.6) < 0.001)
        assertTrue(abs(spans[1].end - 111.2) < 0.001)
        await harness.runtime.waitForShutdown()
    }

    func testReconnectsOnceThenStopsRetryingAndFinalizes() async {
        let harness = makeHarness()

        let ownerID = UUID()
        harness.runtime.handle(action: .start(ownerShortcutID: ownerID, ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        assertEqual(harness.runtime.phase, .recording)
        assertEqual(harness.deepgram.connectCalls.count, 1)

        harness.deepgram.emitConnectionDropped("first")
        await Task.yield()
        harness.scheduler.advance(by: 0.4)
        await Task.yield()
        assertEqual(harness.deepgram.connectCalls.count, 2)

        harness.deepgram.emitConnectionDropped("second")
        await Task.yield()
        harness.scheduler.advance(by: 0.4)
        await Task.yield()
        assertEqual(harness.deepgram.connectCalls.count, 2, "Should not reconnect more than once")
        assertEqual(harness.statuses.value.last, .connectionLostReleaseToFinalize)

        harness.runtime.handle(action: .stop)
        assertEqual(harness.runtime.phase, .finalizing)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
        assertEqual(harness.deepgram.closeStreamCallCount, 1)

        harness.deepgram.completeClose()
        await waitUntil { harness.finalizations.value.count == 1 }
        assertEqual(harness.finalizations.value.count, 1)
        assertEqual(harness.runtime.phase, .idle)
    }

    func testDoesNotReconnectWhileFinalizing() async {
        let harness = makeHarness()

        let ownerID = UUID()
        harness.runtime.handle(action: .start(ownerShortcutID: ownerID, ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        harness.runtime.handle(action: .stop)
        assertEqual(harness.runtime.phase, .finalizing)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }

        harness.deepgram.emitConnectionDropped("during finalize")
        await Task.yield()
        harness.scheduler.advance(by: 1.0)
        await Task.yield()

        assertEqual(harness.deepgram.connectCalls.count, 1)
    }

    func testProviderErrorIsPreservedWhenConnectionThenDrops() async {
        let harness = makeHarness()
        harness.runtime.handle(action: .start(ownerShortcutID: UUID(), ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }

        harness.deepgram.emitTranscriptionError("Provider error: quota exceeded")
        harness.deepgram.emitConnectionDropped("WebSocket receive error: Socket is not connected")
        harness.runtime.handle(action: .stop)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
        harness.deepgram.completeClose()
        await waitUntil { harness.finalizations.value.count == 1 }

        assertEqual(harness.finalizations.value.first?.transcriptionError, "Provider error: quota exceeded")
    }

    func testCancelFromEscWhileFinalizingStopsSessionWithoutFinalizing() async {
        let harness = makeHarness()
        var overlayUpdates: [(Bool, String)] = []
        harness.runtime.onOverlayUpdate = { visible, label, _ in
            overlayUpdates.append((visible, label))
        }

        let ownerID = UUID()
        harness.runtime.handle(action: .start(ownerShortcutID: ownerID, ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        harness.runtime.handle(action: .stop)
        assertEqual(harness.runtime.phase, .finalizing)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }

        harness.runtime.cancelFromEsc()
        assertEqual(harness.runtime.phase, .idle)
        assertEqual(harness.deepgram.disconnectCallCount, 1)
        assertEqual(harness.finalizations.value.count, 0)
        assertEqual(overlayUpdates.last?.0, false)

        harness.deepgram.completeClose()
        await Task.yield()
        assertEqual(harness.finalizations.value.count, 0)
    }

    func testDiscardSilentlyStopsProvisionalRecording() async {
        let harness = makeHarness()

        harness.runtime.handle(action: .start(ownerShortcutID: UUID(), ownerMode: .both, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }

        harness.runtime.handle(action: .discard)

        assertEqual(harness.runtime.phase, .idle)
        assertEqual(harness.statuses.value.last, .idle)
        assertEqual(harness.deepgram.disconnectCallCount, 1)
        assertEqual(harness.finalizations.value.count, 0)
        assertTrue(harness.rawRecordingCapture.discarded)
    }

    func testFinalizeIncludesSavedRawRecordingAndLanguage() async {
        let recordingURL = URL(fileURLWithPath: "/tmp/test-recording.wav")
        let harness = makeHarness()
        harness.rawRecordingCapture.finishResult = recordingURL

        let ownerID = UUID()
        harness.runtime.handle(action: .start(ownerShortcutID: ownerID, ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        harness.runtime.handle(action: .stop)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
        harness.deepgram.completeClose()
        await waitUntil { harness.finalizations.value.count == 1 }

        assertEqual(harness.finalizations.value.first?.rawRecordingFileURL, recordingURL)
        assertEqual(harness.finalizations.value.first?.transcriptionLanguage, .automatic)
        assertEqual(harness.rawRecordingCapture.finishCallCount, 1)
    }

    func testChangingLanguageWhileRecordingReconnectsAndFinalizesWithNewLanguage() async {
        var resolvedLanguage = DeepgramLanguage.english
        let harness = makeHarness(
            resolvedTranscriptionLanguageProvider: { _ in resolvedLanguage }
        )
        var finalizedInterimCount = 0
        harness.runtime.onFinalizeLatestInterim = {
            finalizedInterimCount += 1
        }

        let ownerID = UUID()
        harness.runtime.handle(action: .start(ownerShortcutID: ownerID, ownerMode: .hold, latched: false))
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        assertEqual(harness.deepgram.connectCalls.map(\.language), [.english])

        resolvedLanguage = .french
        harness.runtime.changeTranscriptionLanguage(to: .french)

        assertEqual(harness.deepgram.connectCalls.map(\.language), [.english, .french])
        assertEqual(finalizedInterimCount, 1)

        harness.runtime.handle(action: .stop)
        await waitUntil { harness.deepgram.closeStreamCallCount == 1 }
        harness.deepgram.completeClose()
        await waitUntil { harness.finalizations.value.count == 1 }

        assertEqual(harness.finalizations.value.first?.transcriptionLanguage, .french)
    }

    func testRoutesOneConvertedChunkToRawCaptureAndTranscriptionStream() async {
        let harness = makeHarness()
        harness.runtime.handle(
            action: .start(ownerShortcutID: UUID(), ownerMode: .hold, latched: false)
        )
        await waitUntil { harness.deepgram.connectCalls.count == 1 }
        let audioData = Data([0x10, 0x00, 0x20, 0x00])

        harness.audio.emit(Linear16AudioChunk(data: audioData, meterLevel: 0.5))

        assertEqual(harness.rawRecordingCapture.appendedAudio, [audioData])
        assertEqual(harness.deepgram.sentAudio, [audioData])
    }

    func testCancelDuringPendingCaptureStartCannotOpenAStaleSession() async {
        let harness = makeHarness()
        harness.audio.suspendStart = true
        harness.runtime.handle(
            action: .start(ownerShortcutID: UUID(), ownerMode: .hold, latched: false)
        )
        guard let sessionID = harness.runtime.ownership?.sessionID else { testFailure("Missing session"); return }
        await waitUntil { harness.audio.hasPendingStart }

        harness.runtime.cancelFromEsc()
        assertEqual(harness.runtime.phase, .idle)
        harness.audio.completeStart()
        await harness.runtime.waitForShutdown()
        await waitUntil { harness.audio.stoppedSessionIDs.contains(sessionID) }

        assertTrue(harness.deepgram.connectCalls.isEmpty)
        assertTrue(harness.rawRecordingCapture.appendedAudio.isEmpty)
        assertTrue(harness.finalizations.value.isEmpty)
        assertNil(harness.runtime.ownership)
    }

    private func makeHarness(
        activeApplicationProvider: @escaping () -> ActiveApplicationContext? = { nil },
        resolvedTranscriptionLanguageProvider: @escaping (String?) -> DeepgramLanguage = { _ in .automatic },
        transcriptionSettingsProvider: @escaping () -> TranscriptionProviderSettings = {
            TranscriptionProviderSettings(provider: .deepgram, apiKey: "dg_key")
        },
        resolvedEnhancementPromptProvider: @escaping (UUID?, String?) -> EnhancementPromptContext? = { _, _ in nil }
    ) -> RuntimeHarness {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let audio = FakeAudioCapturePort()
        let deepgram = FakeTranscriptionStreamPort()
        let sound = FakeSoundPort()
        let rawRecordingCapture = FakeRawRecordingCapture()

        let statuses = Box<[AppStatus]>([])
        let finalizations = Box<[RecordingFinalization]>([])

        let runtime = RecordingRuntime(
            audioCapture: audio,
            transcriptionStream: deepgram,
            scheduler: scheduler,
            clock: clock,
            activeApplicationProvider: activeApplicationProvider,
            audioInputSelectionProvider: {
                ResolvedAudioInputSelection(
                    selection: .systemDefault,
                    selectedDevice: nil,
                    systemDefaultDevice: nil
                )
            },
            resolvedTranscriptionLanguageProvider: resolvedTranscriptionLanguageProvider,
            transcriptionSettingsProvider: transcriptionSettingsProvider,
            resolvedEnhancementPromptProvider: resolvedEnhancementPromptProvider,
            playSoundEffectsEnabledProvider: { false },
            muteDuringRecordingProvider: { false },
            rawRecordingCaptureProvider: { _ in rawRecordingCapture },
            soundPort: sound
        )

        runtime.onStatus = { status in
            statuses.value.append(status)
        }
        runtime.onFinalizeRequested = { finalization in
            finalizations.value.append(finalization)
        }

        return RuntimeHarness(
            runtime: runtime,
            audio: audio,
            deepgram: deepgram,
            scheduler: scheduler,
            statuses: statuses,
            finalizations: finalizations,
            rawRecordingCapture: rawRecordingCapture
        )
    }

    private func waitUntil(
        _ message: String = "Timed out waiting for asynchronous runtime work.",
        condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        testFailure(message)
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
