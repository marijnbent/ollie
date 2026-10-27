import Foundation
import OSLog

struct Diagnostics: Sendable {
    static let preferenceKey = "diagnosticsEnabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }
    private let logger: Logger
    private let publicBenchmarkDetails: Bool
    var isEnabled: Bool { Self.enabled }

    init(category: String, publicBenchmarkDetails: Bool = false) {
        self.publicBenchmarkDetails = publicBenchmarkDetails
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "nl.bentjes.fredie", category: category)
    }
    func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .private)")
    }
    func warning(_ name: StaticString, details: @autoclosure () -> String = "") {
        let event = String(describing: name)
        let detail = details()
        logger.warning("\(event, privacy: .public) \(detail, privacy: .private)")
    }

    func error(_ name: StaticString, details: @autoclosure () -> String = "") {
        let event = String(describing: name)
        let detail = details()
        logger.error("\(event, privacy: .public) \(detail, privacy: .private)")
    }

    @discardableResult
    func measure<T>(_ name: @autoclosure () -> String, thresholdMilliseconds: Double = 0, _ work: () -> T) -> T {
        guard isEnabled else {
            return work()
        }

        let start = ContinuousClock.now
        let result = work()
        let milliseconds = Self.milliseconds(from: start.duration(to: .now))

        if milliseconds >= thresholdMilliseconds {
            info("\(name()): \(Self.format(milliseconds)) ms")
        }

        return result
    }

    func benchmark(
        _ name: String,
        since start: ContinuousClock.Instant,
        details: @autoclosure () -> String = ""
    ) {
        benchmark(
            name,
            durationMilliseconds: Self.elapsedMilliseconds(since: start),
            details: details()
        )
    }

    func latency(_ name: String, milliseconds: Double, threshold: Double,
                 details: @autoclosure () -> String = "") {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        guard milliseconds >= threshold else {
            benchmark(name, durationMilliseconds: milliseconds, details: details())
            return
        }
        let duration = Self.format(milliseconds)
        let detail = details()
        if publicBenchmarkDetails {
            logger.warning(
                "lag.\(name, privacy: .public) duration_ms=\(duration, privacy: .public) \(detail, privacy: .public)")
        } else {
            logger.warning(
                "lag.\(name, privacy: .public) duration_ms=\(duration, privacy: .public) \(detail, privacy: .private)")
        }
    }

    func benchmark(
        _ name: String,
        durationMilliseconds: @autoclosure () -> Double,
        details: @autoclosure () -> String = ""
    ) {
        guard isEnabled else {
            return
        }

        let duration = Self.format(durationMilliseconds())
        let detail = details()
        if publicBenchmarkDetails {
            logger.debug("benchmark.\(name, privacy: .public) duration_ms=\(duration, privacy: .public) \(detail, privacy: .public)")
        } else {
            logger.debug("benchmark.\(name, privacy: .public) duration_ms=\(duration, privacy: .public) \(detail, privacy: .private)")
        }
    }

    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(from: start.duration(to: .now))
    }

    static func milliseconds(from duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
