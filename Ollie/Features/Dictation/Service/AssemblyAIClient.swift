import Foundation

protocol AssemblyAISocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: AssemblyAISocket {}

final class AssemblyAIClient: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }

    private let queue = DispatchQueue(label: "Talkie.AssemblyAIClient")
    private let makeSocket: @Sendable (URLRequest) -> any AssemblyAISocket
    private let handshakeTimeout: TimeInterval
    private let closeTimeout: TimeInterval
    private var socket: (any AssemblyAISocket)?
    private var timer: DispatchSourceTimer?
    private var ready = false
    private var closing = false
    private var sending = false
    private var channels = 1
    private var chunkBytes = 3_200
    private var audio = Data()
    private var outbound: [URLSessionWebSocketTask.Message] = []
    private var pendingBytes = 0
    private var lastFinalTurn = -1
    private var onClosed: Completion?
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
        onTimedTranscript: (([TranscriptSpan]) -> Void)? = nil,
        handshakeTimeout: TimeInterval = 15,
        closeTimeout: TimeInterval = 15,
        makeSocket: (@Sendable (URLRequest) -> any AssemblyAISocket)? = nil
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.makeSocket = makeSocket ?? { session.webSocketTask(with: $0) }
        self.handshakeTimeout = handshakeTimeout
        self.closeTimeout = closeTimeout
        self.onTimedTranscript = onTimedTranscript
        self.onTranscriptEvent = onTranscriptEvent
        self.onLog = onLog
        self.onTranscriptionError = onTranscriptionError
        self.onConnectionDropped = onConnectionDropped
    }

    static func languageCodes(for language: DeepgramLanguage, candidates: [DeepgramLanguage]) -> [String] {
        let provider = TranscriptionProvider.assemblyAI
        let normalized = provider.normalizedLanguage(language)
        let languages = normalized == .automatic
            ? provider.normalizedAutomaticLanguageCandidates(candidates) : [normalized]
        return languages.map {
            switch $0 {
            case .afrikaans: "af"
            case .galician: "gl"
            case .mandarinChinese: "zh"
            case .xhosa: "xh"
            case .zulu: "zu"
            default: $0.rawValue
            }
        }
    }

    static func makeRequest(apiKey: String, sampleRate: Int, language: DeepgramLanguage, candidates: [DeepgramLanguage]) -> URLRequest {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        let codes = languageCodes(for: language, candidates: candidates)
        let encodedCodes = "[" + codes.map { "\"" + $0 + "\"" }.joined(separator: ",") + "]"
        components.queryItems = [
            URLQueryItem(name: "speech_model", value: "universal-3-6-pro"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "language_codes", value: encodedCodes),
            URLQueryItem(name: "language_detection", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    func connect(apiKey: String, format: AudioStreamFormat, language: DeepgramLanguage, automaticLanguageCandidates: [DeepgramLanguage]) {
        disconnect()
        guard (8_000...96_000).contains(format.sampleRate), format.channels > 0 else {
            onTranscriptionError?("AssemblyAI requires PCM audio at 8–96 kHz.")
            return
        }
        let socket = makeSocket(Self.makeRequest(apiKey: apiKey, sampleRate: format.sampleRate, language: language, candidates: automaticLanguageCandidates))
        queue.sync {
            self.socket = socket
            channels = format.channels
            chunkBytes = format.sampleRate / 10 * 2
            lastFinalTurn = -1
            scheduleTimeout(handshakeTimeout, message: "AssemblyAI did not accept the audio session in time.")
        }
        socket.resume()
        receive(from: socket)
    }

    func sendAudio(data: Data) {
        queue.async { [weak self] in
            guard let self, self.socket != nil, !self.closing else { return }
            self.audio.append(AudioBufferConverter.monoPCM16(data, channels: self.channels))
            while self.audio.count >= self.chunkBytes {
                self.enqueue(.data(Data(self.audio.prefix(self.chunkBytes))))
                self.audio.removeFirst(self.chunkBytes)
            }
            if self.pendingBytes > self.chunkBytes * 100 {
                self.fail("AssemblyAI could not keep up with the audio stream.", reconnect: true)
            }
        }
    }

    func closeStream(onClosed: @escaping () -> Void) {
        let completion = Completion(onClosed)
        queue.async { [weak self] in
            guard let self, self.socket != nil else { completion.call(); return }
            guard !self.closing else { completion.call(); return }
            self.closing = true
            self.onClosed = completion
            if !self.audio.isEmpty {
                self.audio.append(Data(count: max(0, self.chunkBytes - self.audio.count)))
                self.enqueue(.data(self.audio))
                self.audio = Data()
            }
            self.enqueue(.string("{\"type\":\"Terminate\"}"))
            self.scheduleTimeout(self.closeTimeout, message: "AssemblyAI timed out while finalizing the transcript.")
        }
    }

    func disconnect() {
        queue.sync { cleanup() }
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        if case .data(let data) = message { pendingBytes += data.count }
        outbound.append(message)
        sendNext()
    }

    private func sendNext() {
        guard ready, !sending, !outbound.isEmpty, let socket else { return }
        sending = true
        let message = outbound.removeFirst()
        socket.send(message) { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.socket === socket else { return }
                self.sending = false
                if case .data(let data) = message { self.pendingBytes -= data.count }
                if let error {
                    self.fail("AssemblyAI send failed: \(error.localizedDescription)", reconnect: true)
                } else {
                    self.sendNext()
                }
            }
        }
    }

    private func receive(from socket: any AssemblyAISocket) {
        socket.receive { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, self.socket === socket else { return }
                switch result {
                case .failure(let error):
                    self.fail("AssemblyAI connection closed: \(error.localizedDescription)", reconnect: true)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: return
                    }
                    self.handle(data)
                    if self.socket === socket { self.receive(from: socket) }
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? JSONDecoder().decode(AssemblyAIEvent.self, from: data) else {
            fail("AssemblyAI returned an invalid response.", reconnect: false)
            return
        }
        switch event.type {
        case "Begin":
            guard !ready else { return }
            ready = true
            if !closing { timer?.cancel(); timer = nil }
            onLog?("AssemblyAI Universal-3.6 Pro connected.", .info)
            sendNext()
        case "Turn":
            guard let turn = event.turn_order, turn > lastFinalTurn,
                  let text = event.transcript, !text.trimmed.isEmpty else { return }
            let final = event.end_of_turn == true
            if final { lastFinalTurn = turn }
            onTranscriptEvent?(text, final)
            if final {
                onTimedTranscript?(event.words?.compactMap(\.span) ?? [])
            }
        case "Termination":
            if closing { finishClose() }
            else { fail("AssemblyAI ended the session unexpectedly.", reconnect: true) }
        case "Error", "error":
            fail("AssemblyAI: \(event.error ?? event.message ?? "Provider error.")", reconnect: false)
        default:
            if let error = event.error { fail("AssemblyAI: \(error)", reconnect: false) }
        }
    }

    private func scheduleTimeout(_ seconds: TimeInterval, message: String) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.fail(message, reconnect: true) }
        self.timer = timer
        timer.activate()
    }

    private func fail(_ message: String, reconnect: Bool) {
        onLog?(message, .error)
        if closing {
            onTranscriptionError?(message)
            finishClose()
        } else {
            cleanup()
            if reconnect { onConnectionDropped?(message) }
            else { onTranscriptionError?(message) }
        }
    }

    private func finishClose() {
        let completion = onClosed
        cleanup()
        completion?.call()
    }

    private func cleanup() {
        timer?.cancel()
        timer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        ready = false
        closing = false
        sending = false
        audio = Data()
        outbound = []
        pendingBytes = 0
        onClosed = nil
    }
}

private struct AssemblyAIEvent: Decodable {
    let type: String?
    let turn_order: Int?
    let transcript: String?
    let end_of_turn: Bool?
    let words: [AssemblyAIWord]?
    let error: String?
    let message: String?
}

private struct AssemblyAIWord: Decodable {
    let text: String?
    let start: Double?
    let end: Double?

    var span: TranscriptSpan? {
        guard let text, let start, let end else { return nil }
        let span = TranscriptSpan(text: text, start: start / 1000, end: end / 1000)
        return span.isValid ? span : nil
    }
}
