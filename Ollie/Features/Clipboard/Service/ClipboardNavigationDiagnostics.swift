import Foundation

@MainActor
final class ClipboardNavigationDiagnostics {
    static let previewWaitMilliseconds = 300

    static func previewWorkMilliseconds(total: Double, waited: Double) -> Double {
        max(0, total - min(Double(previewWaitMilliseconds), max(0, waited)))
    }

    enum Stage: String {
        case inputQueue = "clipboard.input_queue"
        case dispatch = "clipboard.key_dispatch"
        case selection = "clipboard.selection"
        case scroll = "clipboard.scroll_offset"
        case previewStart = "clipboard.preview_start"
        case previewWait = "clipboard.preview_wait"
        case previewRead = "clipboard.preview_read"
        case previewImage = "clipboard.preview_image"
        case previewReady = "clipboard.preview_ready"
        case mainActor = "clipboard.main_actor_delay"

        var threshold: Double {
            switch self {
            case .dispatch: 32
            case .previewRead, .previewImage: 50
            case .previewWait: .infinity
            default: 100
            }
        }
    }

    enum Kind: String { case text, image, snippet, none }
    enum Outcome: String { case completed, cancelled, unavailable }

    struct Navigation {
        let sequence: UInt64
        let started: TimeInterval
        let repeating: Bool
        var index = -1
        var kind = Kind.none
        var fileBacked = false
    }

    struct Sample {
        let stage: Stage
        let milliseconds: Double
        let navigation: Navigation
        let outcome: Outcome

        var details: String {
            "nav=\(navigation.sequence) row=\(navigation.index) kind=\(navigation.kind.rawValue) "
                + "file_backed=\(navigation.fileBacked) repeat=\(navigation.repeating) outcome=\(outcome.rawValue)"
        }
    }

    private let now: () -> TimeInterval
    private let emit: (Sample) -> Void
    private var sequence: UInt64 = 0
    private var current: Navigation?
    private var selectedID: String?
    private var recordedScroll = false
    private var checkpoint: Task<Void, Never>?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (Sample) -> Void = { sample in
             Diagnostics(category: "clipboard-performance", publicBenchmarkDetails: true).latency(
                sample.stage.rawValue, milliseconds: sample.milliseconds,
                threshold: sample.stage.threshold, details: sample.details)
         }) {
        self.now = now
        self.emit = emit
    }

    func beginInput(timestamp: TimeInterval, repeating: Bool) -> Navigation {
        stop()
        sequence &+= 1
        let started = now()
        let navigation = Navigation(sequence: sequence, started: started, repeating: repeating)
        current = navigation
        let delay = timestamp > 0 && timestamp <= started ? (started - timestamp) * 1000 : 0
        record(.inputQueue, milliseconds: delay, navigation: navigation)
        let due = started + 0.016
        checkpoint = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, current?.sequence == navigation.sequence else { return }
            record(.mainActor, milliseconds: max(0, now() - due) * 1000, navigation: current)
            checkpoint = nil
        }
        return navigation
    }

    func finishDispatch(_ navigation: Navigation) {
        let latest = current?.sequence == navigation.sequence ? current : navigation
        record(.dispatch, milliseconds: elapsed(since: navigation.started), navigation: latest)
    }

    func selected(id: String?, index: Int, kind: Kind, fileBacked: Bool) {
        guard var navigation = current else { return }
        navigation.index = index
        navigation.kind = kind
        navigation.fileBacked = fileBacked
        current = navigation
        selectedID = id
        record(.selection, milliseconds: elapsed(since: navigation.started), navigation: navigation)
    }

    func scrolled() {
        guard let current, !recordedScroll else { return }
        recordedScroll = true
        record(.scroll, milliseconds: elapsed(since: current.started), navigation: current)
    }

    func preview(for id: String) -> Navigation? {
        guard id == selectedID else { return nil }
        return current
    }

    func time() -> TimeInterval { now() }
    func elapsed(since start: TimeInterval) -> Double { max(0, now() - start) * 1000 }

    func record(_ stage: Stage, milliseconds: Double, navigation: Navigation?, outcome: Outcome = .completed) {
        guard let navigation, milliseconds.isFinite, milliseconds >= 0 else { return }
        emit(Sample(stage: stage, milliseconds: milliseconds, navigation: navigation, outcome: outcome))
    }

    func stop() {
        checkpoint?.cancel()
        checkpoint = nil
        current = nil
        selectedID = nil
        recordedScroll = false
    }
}
