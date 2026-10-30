import Foundation

protocol RawRecordingCapture: AnyObject, Sendable {
    func append(data: Data)
    func finish() async throws -> URL?
    func discard()
}

final class RawRecordingStore {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let legacyBaseDirectory: URL?

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        legacyBaseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        if let legacyBaseDirectory {
            self.legacyBaseDirectory = legacyBaseDirectory

        } else {
            self.legacyBaseDirectory = nil
        }
        prepareBaseDirectory()
    }

    func makeCapture(format: AudioStreamFormat) -> RawRecordingCapture {
        FileRawRecordingCapture(
            format: format,
            fileManager: fileManager,
            baseDirectory: baseDirectory
        )
    }

    func deleteRecording(at url: URL?) {
        guard let url else { return }
        let target = url.standardizedFileURL
        guard managedDirectories.contains(where: { Self.isDirectChild(target, of: $0) }) else {
            return
        }
        try? fileManager.removeItem(at: target)
    }

    func migrateLegacyRecordings(in entries: [TranscriptHistoryEntry]) -> [TranscriptHistoryEntry] {
        entries.map { entry in
            guard let sourceURL = entry.rawRecordingFileURL else { return entry }
            let migratedURL = migrateLegacyRecordingIfNeeded(at: sourceURL)
            guard migratedURL != sourceURL.standardizedFileURL else { return entry }

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
                rawRecordingFileURL: migratedURL,
                transcriptionLanguage: entry.transcriptionLanguage,
                usedActiveAppPrompt: entry.usedActiveAppPrompt,
                sourceFileName: entry.sourceFileName
            )
        }
    }

    func pruneRecordings(keeping urls: [URL]) {
        let allowedPaths = Set(
            urls.map { $0.standardizedFileURL.path }
        )

        for directory in managedDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in contents {
                let path = url.standardizedFileURL.path
                if !allowedPaths.contains(path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    private var managedDirectories: [URL] {
        var paths = Set<String>()
        return [baseDirectory, legacyBaseDirectory].compactMap { directory in
            guard let directory else { return nil }
            let standardizedDirectory = directory.standardizedFileURL
            guard paths.insert(standardizedDirectory.path).inserted else { return nil }
            return standardizedDirectory
        }
    }

    private func migrateLegacyRecordingIfNeeded(at url: URL) -> URL {
        let sourceURL = url.standardizedFileURL
        let destinationDirectory = baseDirectory.standardizedFileURL
        guard let legacyBaseDirectory = legacyBaseDirectory?.standardizedFileURL,
              legacyBaseDirectory != destinationDirectory,
              Self.isDirectChild(sourceURL, of: legacyBaseDirectory),
              sourceURL.pathExtension.lowercased() == "wav" else {
            return sourceURL
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return sourceURL
        }

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destinationURL = availableDestinationURL(for: sourceURL, in: destinationDirectory)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return sourceURL
        }
    }

    private func availableDestinationURL(for sourceURL: URL, in directory: URL) -> URL {
        let preferredURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        var candidateURL: URL
        repeat {
            candidateURL = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
        } while fileManager.fileExists(atPath: candidateURL.path)
        return candidateURL
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
    }

    private func prepareBaseDirectory() {
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private static func defaultBaseDirectory(fileManager: FileManager) -> URL {
        AppPaths.applicationSupport().appendingPathComponent("Dictation/Recordings", isDirectory: true)
    }

    private static func defaultLegacyBaseDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("Talkie/HistoryAudio", isDirectory: true)
    }
}

private final class FileRawRecordingCapture: RawRecordingCapture, @unchecked Sendable {
    private enum CaptureError: LocalizedError {
        case alreadyFinished
        case couldNotCreateTemporaryFile
        case invalidFormat
        case recordingTooLarge

        var errorDescription: String? {
            switch self {
            case .alreadyFinished:
                return "The raw recording is already complete."
            case .couldNotCreateTemporaryFile:
                return "Could not create the temporary raw recording file."
            case .invalidFormat:
                return "The raw recording uses an invalid audio format."
            case .recordingTooLarge:
                return "The raw recording is too large for a WAV file."
            }
        }
    }

    private enum Lifecycle {
        case active
        case finishing
        case finished(URL?)
        case discarded
    }

    private let format: AudioStreamFormat
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let ioQueue = DispatchQueue(label: "Talkie.RawRecordingCapture.IO")
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .active

    private var fileHandle: FileHandle?
    private var temporaryURL: URL?
    private var finalURL: URL?
    private var pcmByteCount: UInt64 = 0
    private var writeError: Error?

    init(format: AudioStreamFormat, fileManager: FileManager, baseDirectory: URL) {
        self.format = format
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
    }

    func append(data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard case .active = lifecycle else {
            lock.unlock()
            return
        }
        ioQueue.async { [self] in
            appendOnIOQueue(data)
        }
        lock.unlock()
    }

    func finish() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard case .active = lifecycle else {
                lock.unlock()
                continuation.resume(throwing: CaptureError.alreadyFinished)
                return
            }
            lifecycle = .finishing
            ioQueue.async { [self] in
                let result = Result { try finishOnIOQueue() }
                let shouldDiscard = lock.withLock {
                    if case .discarded = lifecycle {
                        return true
                    }
                    lifecycle = .finished(try? result.get())
                    return false
                }

                if shouldDiscard {
                    cleanupFilesOnIOQueue()
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(with: result)
                }
            }
            lock.unlock()
        }
    }

    func discard() {
        lock.lock()
        guard case .discarded = lifecycle else {
            lifecycle = .discarded
            ioQueue.async { [self] in
                cleanupFilesOnIOQueue()
            }
            lock.unlock()
            return
        }
        lock.unlock()
    }

    private func appendOnIOQueue(_ data: Data) {
        guard writeError == nil else { return }

        do {
            let handle = try openFileIfNeededOnIOQueue()
            try handle.write(contentsOf: data)
            pcmByteCount += UInt64(data.count)
        } catch {
            writeError = error
        }
    }

    private func openFileIfNeededOnIOQueue() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }

        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let recordingID = UUID().uuidString
        let temporaryURL = baseDirectory
            .appendingPathComponent(recordingID)
            .appendingPathExtension("wav.partial")
        let finalURL = baseDirectory
            .appendingPathComponent(recordingID)
            .appendingPathExtension("wav")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: Data(count: 44), attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.couldNotCreateTemporaryFile
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.seekToEnd()
        self.fileHandle = handle
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        return handle
    }

    private func finishOnIOQueue() throws -> URL? {
        do {
            if let writeError {
                throw writeError
            }

            guard pcmByteCount > 0 else {
                cleanupFilesOnIOQueue()
                return nil
            }
            guard let fileHandle, let temporaryURL, let finalURL else {
                cleanupFilesOnIOQueue()
                return nil
            }

            let header = try Self.wavHeader(
                pcmByteCount: pcmByteCount,
                sampleRate: format.sampleRate,
                channels: format.channels
            )
            try fileHandle.seek(toOffset: 0)
            try fileHandle.write(contentsOf: header)
            try fileHandle.synchronize()
            try fileHandle.close()
            self.fileHandle = nil
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            self.temporaryURL = nil
            return finalURL
        } catch {
            cleanupFilesOnIOQueue()
            throw error
        }
    }

    private func cleanupFilesOnIOQueue() {
        try? fileHandle?.close()
        fileHandle = nil
        if let temporaryURL {
            try? fileManager.removeItem(at: temporaryURL)
            self.temporaryURL = nil
        }
        if let finalURL {
            try? fileManager.removeItem(at: finalURL)
            self.finalURL = nil
        }
    }

    private static func wavHeader(
        pcmByteCount: UInt64,
        sampleRate: Int,
        channels: Int
    ) throws -> Data {
        let bytesPerSample = 2
        guard sampleRate > 0,
              channels > 0,
              let sampleRate32 = UInt32(exactly: sampleRate),
              let channels16 = UInt16(exactly: channels),
              let blockAlign = UInt16(exactly: channels * bytesPerSample),
              let byteRate = UInt32(exactly: sampleRate * channels * bytesPerSample) else {
            throw CaptureError.invalidFormat
        }
        guard let pcmByteCount32 = UInt32(exactly: pcmByteCount),
              pcmByteCount32 <= UInt32.max - 36 else {
            throw CaptureError.recordingTooLarge
        }

        var data = Data()
        data.reserveCapacity(44)
        data.append("RIFF".data(using: .ascii)!)
        data.appendLE(36 + pcmByteCount32)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels16)
        data.appendLE(sampleRate32)
        data.appendLE(byteRate)
        data.appendLE(UInt16(blockAlign))
        data.appendLE(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLE(pcmByteCount32)
        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }
}
