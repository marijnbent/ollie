import Foundation

final class ElevenLabsClient: NSObject, @unchecked Sendable {
    private final class CompletionBox: @unchecked Sendable {
        let callback: () -> Void

        init(_ callback: @escaping () -> Void) {
            self.callback = callback
        }
    }

    private static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    private static let model = "scribe_v2_realtime"
    private static let closeTimeoutSeconds: TimeInterval = 3
    private static let supportedSampleRates: Set<Int> = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

    private let session: URLSession
    private let queue = DispatchQueue(label: "Talkie.ElevenLabsClient")
    private let queueKey = DispatchSpecificKey<Void>()
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isClosing = false
    private var sampleRate = 16_000
    private var channels = 1
    private var onClose: (() -> Void)?
    private var closeTimer: DispatchSourceTimer?

    private var includeTimings = false
    private let onTimedTranscript: (([TranscriptSpan]) -> Void)?
    private let onTranscriptEvent: ((String, Bool) -> Void)?
    private let onLog: ((String, LogLevel) -> Void)?
    private let onTranscriptionError: ((String) -> Void)?
    private let onConnectionDropped: ((String) -> Void)?

    init(
        onTranscriptEvent: ((String, Bool) -> Void)? = nil,
        onLog: ((String, LogLevel) -> Void)? = nil,
        onTranscriptionError: ((String) -> Void)? = nil,
        onConnectionDropped: ((String) -> Void)? = nil,
        onTimedTranscript: (([TranscriptSpan]) -> Void)? = nil
    ) {
        session = URLSession(configuration: .default)
        self.onTimedTranscript = onTimedTranscript
        self.onTranscriptEvent = onTranscriptEvent
        self.onLog = onLog
        self.onTranscriptionError = onTranscriptionError
        self.onConnectionDropped = onConnectionDropped
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    func connect(
        apiKey: String,
        format: AudioStreamFormat,
        language: DeepgramLanguage,
        automaticLanguageCandidates: [DeepgramLanguage] = TranscriptionProvider.elevenLabs.defaultAutomaticLanguageCandidates,
        includeTimings: Bool = false
    ) {
        disconnect(logDisconnection: false)

        guard Self.supportedSampleRates.contains(format.sampleRate) else {
            reportTranscriptionError("ElevenLabs does not support \(format.sampleRate) Hz audio.")
            return
        }
        guard format.channels > 0 else {
            reportTranscriptionError("ElevenLabs requires at least one audio channel.")
            return
        }

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: Self.model),
            URLQueryItem(name: "audio_format", value: Self.audioFormat(for: format.sampleRate)),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        if includeTimings { components.queryItems?.append(URLQueryItem(name: "include_timestamps", value: "true")) }
        components.queryItems?.append(
            contentsOf: Self.languageQueryItems(
                for: language,
                automaticLanguageCandidates: automaticLanguageCandidates
            )
        )

        guard let url = components.url else {
            reportTranscriptionError("Failed to build ElevenLabs URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = session.webSocketTask(with: request)
        queue.sync {
            self.task = task
            self.includeTimings = includeTimings
            self.sampleRate = format.sampleRate
            self.channels = format.channels
            self.isConnected = true
            self.isClosing = false
            self.closeTimer?.cancel()
            self.closeTimer = nil
        }
        task.resume()
        onLog?("WebSocket connecting to ElevenLabs.", .info)
        receiveLoop(for: task)
    }

    func sendAudio(data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self,
                  let task = self.task,
                  self.isConnected,
                  !self.isClosing else { return }

            let monoData = AudioBufferConverter.monoPCM16(data, channels: self.channels)
            let message = ElevenLabsInputAudioChunk(
                audioBase64: monoData.base64EncodedString(),
                commit: false,
                sampleRate: self.sampleRate
            )
            guard let payload = try? JSONEncoder().encode(message),
                  let text = String(data: payload, encoding: .utf8) else {
                self.reportTranscriptionError("Failed to encode ElevenLabs audio.")
                return
            }
            task.send(.string(text)) { [weak self] error in
                guard let self, let error, !Self.isCancellationError(error) else { return }
                self.queue.async { [weak self] in
                    self?.handleUnexpectedConnectionDropOnQueue(
                        "ElevenLabs WebSocket send error: \(error.localizedDescription)",
                        task: task
                    )
                }
            }
        }
    }

    func closeStream(onClosed: @escaping () -> Void) {
        let completion = CompletionBox(onClosed)
        queue.async { [weak self] in
            guard let self else {
                completion.callback()
                return
            }

            guard let task = self.task else {
                self.onClose = nil
                self.isClosing = false
                self.isConnected = false
                completion.callback()
                return
            }

            self.isClosing = true
            self.isConnected = false
            self.onClose = completion.callback

            let message = ElevenLabsInputAudioChunk(
                audioBase64: "",
                commit: true,
                sampleRate: self.sampleRate
            )
            if let payload = try? JSONEncoder().encode(message),
               let text = String(data: payload, encoding: .utf8) {
                task.send(.string(text)) { [weak self] error in
                    guard let self, let error,
                          !Self.isCancellationError(error) else { return }
                    self.onLog?("Failed to commit ElevenLabs stream: \(error.localizedDescription)", .warning)
                }
            }
            self.onLog?("Sent commit to ElevenLabs.", .info)
            self.scheduleCloseTimeoutOnQueue()
        }
    }

    func disconnect() {
        disconnect(logDisconnection: true)
    }

    private func disconnect(logDisconnection: Bool) {
        let hadConnection = queue.sync { () -> Bool in
            let hadConnection = isConnected || isClosing || task != nil
            isConnected = false
            isClosing = false
            closeTimer?.cancel()
            closeTimer = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            onClose = nil
            return hadConnection
        }
        if hadConnection && logDisconnection {
            onLog?("ElevenLabs WebSocket disconnected.", .info)
        }
    }

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.queue.sync(execute: { self.task === task }) else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncoming(text: text, for: task)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncoming(text: text, for: task)
                    } else {
                        self.reportTranscriptionError("ElevenLabs returned invalid UTF-8 data.")
                    }
                @unknown default:
                    break
                }
            case .failure(let error):
                self.queue.async { [weak self] in
                    guard let self, self.task === task else { return }
                    if self.isClosing {
                        self.finishCloseOnQueue()
                    } else if !Self.isCancellationError(error) {
                        self.handleUnexpectedConnectionDropOnQueue(
                            "ElevenLabs WebSocket receive error: \(error.localizedDescription)",
                            task: task
                        )
                    }
                }
                return
            }

            let shouldContinue = self.queue.sync {
                self.task === task && (self.isConnected || self.isClosing)
            }
            if shouldContinue {
                self.receiveLoop(for: task)
            }
        }
    }

    private func handleIncoming(text: String, for task: URLSessionWebSocketTask) {
        guard queue.sync(execute: { self.task === task }), let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(ElevenLabsRealtimeEvent.self, from: data) else {
            onLog?("Failed to decode ElevenLabs message. Preview: \(Self.preview(text))", .warning)
            return
        }

        switch event.messageType {
        case "partial_transcript", "final_transcript", "final_transcript_with_timestamps":
            if let text = event.text, !text.isEmpty {
                onTranscriptEvent?(text, false)
            }
        case "committed_transcript", "committed_transcript_with_timestamps":
            if let text = event.text, !text.isEmpty {
                onTranscriptEvent?(text, true)
            }
            if event.messageType == "committed_transcript_with_timestamps" { onTimedTranscript?(event.spans) }
            let shouldFinish = queue.sync {
                self.task === task && self.isClosing
                    && event.completesCommit(includingTimings: self.includeTimings)
            }
            if shouldFinish {
                finishClose()
            }
        case "session_started":
            onLog?("ElevenLabs WebSocket connected.", .info)
        default:
            if let error = event.error, !error.isEmpty {
                reportTranscriptionError("ElevenLabs error: \(error)")
            }
        }
    }

    private func handleUnexpectedConnectionDropOnQueue(_ message: String, task: URLSessionWebSocketTask) {
        guard self.task === task, !isClosing else { return }
        isConnected = false
        self.task = nil
        onLog?(message, .error)
        onConnectionDropped?(message)
    }

    private func scheduleCloseTimeout() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            scheduleCloseTimeoutOnQueue()
        } else {
            queue.async { [weak self] in self?.scheduleCloseTimeoutOnQueue() }
        }
    }

    private func scheduleCloseTimeoutOnQueue() {
        guard isClosing else { return }
        closeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.closeTimeoutSeconds)
        timer.setEventHandler { [weak self] in self?.finishCloseOnQueue() }
        closeTimer = timer
        timer.activate()
    }

    private func finishClose() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            finishCloseOnQueue()
        } else {
            queue.async { [weak self] in self?.finishCloseOnQueue() }
        }
    }

    private func finishCloseOnQueue() {
        guard isClosing else { return }
        isClosing = false
        let callback = onClose
        onClose = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        closeTimer?.cancel()
        closeTimer = nil
        onLog?("ElevenLabs WebSocket closed.", .info)
        callback?()
    }

    private func reportTranscriptionError(_ message: String) {
        onLog?(message, .error)
        onTranscriptionError?(message)
    }

    private static func audioFormat(for sampleRate: Int) -> String {
        "pcm_\(sampleRate)"
    }

    static func makeInputAudioMessage(
        audio: Data,
        commit: Bool = false,
        sampleRate: Int
    ) throws -> String {
        let message = ElevenLabsInputAudioChunk(
            audioBase64: audio.base64EncodedString(),
            commit: commit,
            sampleRate: sampleRate
        )
        let data = try JSONEncoder().encode(message)
        return String(decoding: data, as: UTF8.self)
    }

    static func languageQueryItems(
        for language: DeepgramLanguage,
        automaticLanguageCandidates: [DeepgramLanguage] = TranscriptionProvider.elevenLabs.defaultAutomaticLanguageCandidates
    ) -> [URLQueryItem] {
        if let languageCode = elevenLabsLanguageCode(for: language) {
            return [URLQueryItem(name: "language_code", value: languageCode)]
        }

        let normalizedCandidates = TranscriptionProvider.elevenLabs.normalizedAutomaticLanguageCandidates(
            automaticLanguageCandidates
        )
        return normalizedCandidates.compactMap {
            guard let languageCode = elevenLabsLanguageCode(for: $0) else { return nil }
            return URLQueryItem(name: "secondary_languages", value: languageCode)
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func preview(_ text: String, maxLength: Int = 180) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "…"
    }
}

func elevenLabsLanguageCode(for language: DeepgramLanguage) -> String? {
    guard language != .automatic else { return nil }

    switch language {
    case .cantonese, .chineseCantonese:
        return "yue"
    case .mandarinChinese,
         .chineseMandarinSimplified,
         .chineseMandarinSimplifiedChina,
         .chineseMandarinSimplifiedHans,
         .chineseMandarinTraditional,
         .chineseMandarinTraditionalHant:
        return "zho"
    case .filipino, .tagalog:
        return "fil"
    default:
        break
    }

    return language.deepgramCode.split(separator: "-", maxSplits: 1).first.map(String.init)
}

struct ElevenLabsInputAudioChunk: Codable, Equatable {
    let audioBase64: String
    let commit: Bool
    let sampleRate: Int

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base_64"
        case commit
        case messageType = "message_type"
        case sampleRate = "sample_rate"
    }

    init(audioBase64: String, commit: Bool, sampleRate: Int) {
        self.audioBase64 = audioBase64
        self.commit = commit
        self.sampleRate = sampleRate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioBase64, forKey: .audioBase64)
        try container.encode(commit, forKey: .commit)
        try container.encode("input_audio_chunk", forKey: .messageType)
        try container.encode(sampleRate, forKey: .sampleRate)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioBase64 = try container.decode(String.self, forKey: .audioBase64)
        commit = try container.decodeIfPresent(Bool.self, forKey: .commit) ?? false
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
    }
}
