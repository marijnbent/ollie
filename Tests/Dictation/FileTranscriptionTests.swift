import AVFoundation
import Foundation

@MainActor
enum FileTranscriptionTests {
    static func run() async throws {
        try await audioOnlyConversion()
        await historyAndCancellation()
    }

    private static func audioOnlyConversion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("source.wav")
        let qta = directory.appendingPathComponent("memo.qta")
        let output = directory.appendingPathComponent("transcription.wav")
        try writeTone(to: wav)
        try await makeQuickTimeAudio(source: wav, destination: qta)
        let original = try Data(contentsOf: qta)
        assertTrue(original.range(of: Data("BUILT_IN_TRANSCRIPT".utf8)) != nil)
        try await TranscriptionAudioFile.prepare(source: qta, destination: output)
        assertEqual(try Data(contentsOf: qta), original)
        let audio = try AVAudioFile(forReading: output)
        assertEqual(audio.fileFormat.sampleRate, 16_000)
        assertEqual(audio.fileFormat.channelCount, 1)
        assertTrue(audio.length > 0)
        let exported = try Data(contentsOf: output)
        assertNil(exported.range(of: Data("BUILT_IN_TRANSCRIPT".utf8)))
        assertEqual(String(bytes: exported.prefix(4), encoding: .ascii), "RIFF")
        assertTrue(try MusePrerecordedClient.normalizedWAV(exported).count > 44)
        let multipart = try ElevenLabsPrerecordedClient.makeMultipartFile(
            fileURL: output, language: .dutch, boundary: "test-boundary"
        )
        defer { try? FileManager.default.removeItem(at: multipart) }
        let request = try Data(contentsOf: multipart)
        assertTrue(request.range(of: Data("scribe_v2\r\n".utf8)) != nil)
        assertNil(request.range(of: Data("scribe_v2_realtime".utf8)))
        assertTrue(request.range(of: exported) != nil)
        let ending = Data("\r\n--test-boundary--\r\n".utf8)
        assertEqual(request.suffix(ending.count), ending)
        let buffer = try unwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_000))
        try audio.read(into: buffer)
        assertTrue((0..<Int(buffer.frameLength)).contains { abs(buffer.floatChannelData![0][$0]) > 0.01 })

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await TranscriptionAudioFile.prepare(source: qta, destination: directory.appendingPathComponent("cancelled.wav"))
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            testFailure("Cancelled import must stop")
        } catch is CancellationError {
        }
    }

    private static func writeTone(to url: URL) throws {
        let format = try unwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try unwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 440 * 2 * .pi / 48_000) * 0.2)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func makeQuickTimeAudio(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let track = try unwrap(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let transcript = AVMutableMetadataItem()
        transcript.identifier = .quickTimeMetadataDescription
        transcript.value = "BUILT_IN_TRANSCRIPT" as NSString
        writer.metadata = [transcript]
        let receiver = writer.inputReceiver(for: AVAssetWriterInput(mediaType: .audio, outputSettings: nil))
        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        while let sample = try await provider.next() { try await receiver.append(sample) }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func historyAndCancellation() async {
        let settings = TranscriptionProviderSettings(provider: .elevenLabs, apiKey: "test-key")
        let source = URL(fileURLWithPath: "/test/memo.qta")
        let session = DictationSessionState()
        let controller = FileTranscriptionController(session: session) { file, configured, language in
            assertEqual(file, source)
            assertEqual(configured.provider, .elevenLabs)
            assertEqual(language, .dutch)
            return " Fresh transcript. "
        }
        controller.start(fileURL: source, settings: settings, language: .dutch, historyLimit: { .hundred })
        controller.start(fileURL: source.appendingPathExtension("duplicate"), settings: settings,
                         language: .automatic, historyLimit: { .hundred })
        await controller.finish()
        assertEqual(session.transcriptHistory.first?.text, "Fresh transcript.")
        assertEqual(session.transcriptHistory.first?.sourceFileName, "memo.qta")
        do {
            let data = try JSONEncoder().encode(session.transcriptHistory)
            let restored = try JSONDecoder().decode([TranscriptHistoryEntry].self, from: data)
            assertEqual(restored.first?.sourceFileName, "memo.qta")
        } catch {
            testFailure("Imported filename must survive history persistence")
        }
        assertNil(session.transcriptHistory.first?.rawRecordingFileURL)
        assertFalse(controller.isTranscribing)
        var limit = DictationHistoryLimit.hundred
        controller.start(fileURL: source, settings: settings, language: .dutch, historyLimit: { limit })
        limit = .none
        await controller.finish()
        assertEqual(controller.result?.text, "Fresh transcript.")
        assertEqual(session.transcriptHistory.count, 1)

        let cancelled = FileTranscriptionController(session: session) { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return "Must not be saved"
        }
        cancelled.start(fileURL: source, settings: settings, language: .automatic, historyLimit: { .hundred })
        cancelled.cancel()
        await cancelled.finish()
        assertNil(cancelled.result)
        assertNil(cancelled.error)
        assertEqual(session.transcriptHistory.count, 1)

        let empty = FileTranscriptionController(session: session) { _, _, _ in " " }
        empty.start(fileURL: source, settings: settings, language: .automatic, historyLimit: { .hundred })
        await empty.finish()
        assertTrue(empty.error != nil)
        assertEqual(session.transcriptHistory.count, 1)
        let missing = FileTranscriptionController(session: session) { _, _, _ in
            preconditionFailure("Missing credentials must not call the provider")
        }
        missing.start(
            fileURL: source, settings: .init(provider: .elevenLabs, apiKey: ""),
            language: .automatic, historyLimit: { .hundred }
        )
        assertFalse(missing.isTranscribing)
        assertTrue(missing.error != nil)
    }
}
