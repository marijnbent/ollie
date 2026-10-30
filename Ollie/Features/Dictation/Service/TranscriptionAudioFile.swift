import AVFoundation
import Foundation

enum TranscriptionAudioFile {
    nonisolated static func prepare(source: URL, destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioFileError.noAudio }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(output) else { throw AudioFileError.unsupportedAudio }
        let provider = reader.outputProvider(for: output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else { throw AudioFileError.unsupportedAudio }
        let receiver = writer.inputReceiver(for: input)
        defer {
            reader.cancelReading()
            if writer.status != .completed { writer.cancelWriting() }
        }
        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        var hasAudio = false
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            try await receiver.append(sample)
            hasAudio = true
        }
        guard hasAudio else { throw AudioFileError.noAudio }
        receiver.finish()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? AudioFileError.unsupportedAudio
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

enum AudioFileError: LocalizedError {
    case noAudio
    case unsupportedAudio
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .noAudio: "This file contains no audio. Choose another recording."
        case .unsupportedAudio: "This audio could not be decoded. Export the recording as M4A or WAV and try again."
        case .noTranscript: "No speech was detected in this recording."
        }
    }
}
