import Foundation

final class DeepgramClient: NSObject, @unchecked Sendable {
    private let session: URLSession
    private let queue = DispatchQueue(label: "Talkie.DeepgramClient")
    private let queueKey = DispatchSpecificKey<Void>()
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isClosing = false
    private let onTimedTranscript: (([TranscriptSpan]) -> Void)?
    private let onTranscriptEvent: ((String, Bool) -> Void)?
    private let onLog: ((String, LogLevel) -> Void)?
    private let onTranscriptionError: ((String) -> Void)?
    private let onConnectionDropped: ((String) -> Void)?
    private var onClose: (() -> Void)?
    private var closeTimer: DispatchSourceTimer?
    private var decodeFailureCount = 0
    private var binaryDecodeFailureCount = 0

    private let closeTimeoutSeconds: TimeInterval = 3.0

    init(
        onTranscriptEvent: ((String, Bool) -> Void)? = nil,
        onLog: ((String, LogLevel) -> Void)? = nil,
        onTranscriptionError: ((String) -> Void)? = nil,
        onConnectionDropped: ((String) -> Void)? = nil,
        onTimedTranscript: (([TranscriptSpan]) -> Void)? = nil
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
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
        language: DeepgramLanguage
    ) {
        disconnect(logDisconnection: false)

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"

        let queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(format.sampleRate)),
            URLQueryItem(name: "channels", value: String(format.channels)),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language.deepgramCode),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "100"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        components.queryItems = queryItems

        guard let url = components.url else {
            reportTranscriptionError("Failed to build Deepgram URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        queue.sync {
            self.task = task
            self.isConnected = true
            self.isClosing = false
            self.closeTimer?.cancel()
            self.closeTimer = nil
        }
        task.resume()
        onLog?("WebSocket connecting to \(url.absoluteString)", .info)

        receiveLoop(for: task)
    }

    func sendAudio(data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard let task = self.task, self.isConnected, !self.isClosing else { return }

            task.send(.data(data)) { [weak self] error in
                guard let self, let error else { return }
                guard !Self.isCancellationError(error) else { return }

                self.queue.async { [weak self] in
                    guard let self else { return }
                    let message = "WebSocket send error: \(error.localizedDescription)"
                    self.handleUnexpectedConnectionDropOnQueue(message, task: task)
                }
            }
        }
    }

    func closeStream(onClosed: @escaping () -> Void) {
        let task = queue.sync { self.task }
        guard let task else {
            queue.sync {
                onClose = nil
                isClosing = false
                isConnected = false
            }
            onClosed()
            return
        }

        queue.sync {
            isClosing = true
            isConnected = false
            onClose = onClosed
        }

        let finalizeMessage = "{\"type\":\"Finalize\"}"
        task.send(.string(finalizeMessage)) { [weak self] error in
            guard let self else { return }
            if let error {
                let shouldIgnore = self.queue.sync {
                    self.task !== task || !self.isClosing
                }
                if !shouldIgnore && !Self.isCancellationError(error) {
                    self.onLog?("Failed to send Finalize: \(error.localizedDescription)", .warning)
                }
            } else {
                let shouldLogSuccess = self.queue.sync {
                    self.task === task && self.isClosing
                }
                if shouldLogSuccess {
                    self.onLog?("Sent Finalize to Deepgram.", .info)
                }
            }
            self.sendCloseStreamMessage(on: task)
        }

        scheduleCloseTimeout()
    }

    private func sendCloseStreamMessage(on task: URLSessionWebSocketTask) {
        let closeMessage = "{\"type\":\"CloseStream\"}"
        task.send(.string(closeMessage)) { [weak self] error in
            guard let self else { return }
            if let error {
                let shouldIgnore = self.queue.sync {
                    self.task !== task || !self.isClosing
                }
                if shouldIgnore || Self.isCancellationError(error) {
                    return
                }
                self.onLog?("Failed to send CloseStream: \(error.localizedDescription)", .error)
            } else {
                let shouldLogSuccess = self.queue.sync {
                    self.task === task && self.isClosing
                }
                if shouldLogSuccess {
                    self.onLog?("Sent CloseStream to Deepgram.", .info)
                }
            }
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
            onLog?("WebSocket disconnected.", .info)
        }
    }

    private func receiveLoop(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            let isCurrentTask = self.queue.sync { self.task === task }
            guard isCurrentTask else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncoming(text: text, for: task)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncoming(text: text, for: task)
                    } else {
                        let failureCount = self.queue.sync { () -> Int in
                            self.binaryDecodeFailureCount += 1
                            return self.binaryDecodeFailureCount
                        }
                        if Self.shouldLogOccurrence(failureCount) {
                            self.onLog?(
                                "Received non-UTF8 Deepgram data frame (\(data.count) bytes, \(failureCount) decode failures).",
                                .warning
                            )
                        }
                    }
                @unknown default:
                    break
                }
            case .failure(let error):
                self.queue.async { [weak self] in
                    guard let self else { return }
                    guard self.task === task else { return }

                    if self.isClosing {
                        self.finishCloseOnQueue()
                        return
                    }

                    if Self.isCancellationError(error) {
                        return
                    }

                    let message = "WebSocket receive error: \(error.localizedDescription)"
                    self.handleUnexpectedConnectionDropOnQueue(message, task: task)
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
        guard queue.sync(execute: { self.task === task }), let data = text.data(using: .utf8) else { return }
        guard let result = try? JSONDecoder().decode(DeepgramLiveResult.self, from: data) else {
            let failureCount = queue.sync { () -> Int in
                decodeFailureCount += 1
                return decodeFailureCount
            }
            if Self.shouldLogOccurrence(failureCount) {
                onLog?(
                    "Failed to decode Deepgram message (\(failureCount) failures). Preview: \(Self.preview(text))",
                    .warning
                )
            }
            return
        }

        if let transcript = result.transcript, !transcript.isEmpty {
            let isFinal = (result.is_final ?? false) || (result.speech_final ?? false) || (result.from_finalize ?? false)
            onTranscriptEvent?(transcript, isFinal)
            if isFinal { onTimedTranscript?(result.channel?.alternatives?.first?.words?.compactMap(\.span) ?? []) }
        }

        if result.type == "Error", let description = result.errorDescription {
            reportTranscriptionError("Deepgram error: \(description)")
        }

        let shouldFinishAfterFinalize = queue.sync {
            self.task === task && isClosing && ((result.from_finalize ?? false) || result.type == "Finalize")
        }
        if shouldFinishAfterFinalize {
            finishClose()
        }
    }

    private func handleUnexpectedConnectionDropOnQueue(_ message: String, task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        guard !isClosing else { return }

        isConnected = false
        self.task = nil
        onLog?(message, .error)
        onConnectionDropped?(message)
    }

    private func scheduleCloseTimeout() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            scheduleCloseTimeoutOnQueue()
        } else {
            queue.async { [weak self] in
                self?.scheduleCloseTimeoutOnQueue()
            }
        }
    }

    private func scheduleCloseTimeoutOnQueue() {
        guard isClosing else { return }
        closeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + closeTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            self?.finishCloseOnQueue()
        }
        closeTimer = timer
        timer.activate()
    }

    private func finishClose() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            finishCloseOnQueue()
        } else {
            queue.async { [weak self] in
                self?.finishCloseOnQueue()
            }
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
        onLog?("WebSocket closed after CloseStream.", .info)
        callback?()
    }

    private func reportTranscriptionError(_ message: String) {
        onLog?(message, .error)
        onTranscriptionError?(message)
    }

    private static func shouldLogOccurrence(_ occurrence: Int) -> Bool {
        occurrence <= 3 || occurrence % 100 == 0
    }

    private static func preview(_ text: String, maxLength: Int = 180) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmed
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "…"
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct DeepgramLiveResult: Decodable {
    let type: String?
    let channel: DeepgramChannel?
    let is_final: Bool?
    let speech_final: Bool?
    let from_finalize: Bool?
    let errorDescription: String?

    var transcript: String? {
        channel?.alternatives?.first?.transcript
    }

    enum CodingKeys: String, CodingKey {
        case type
        case channel
        case is_final
        case speech_final
        case from_finalize
        case errorDescription = "description"
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]?
}

private struct DeepgramAlternative: Decodable {
    let transcript: String?
    let words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    let word: String?
    let punctuated_word: String?
    let start: Double?
    let end: Double?

    var span: TranscriptSpan? {
        guard let text = punctuated_word ?? word, let start, let end else { return nil }
        let span = TranscriptSpan(text: text, start: start, end: end)
        return span.isValid ? span : nil
    }
}
