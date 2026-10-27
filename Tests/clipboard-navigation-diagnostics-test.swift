import Foundation

@main
@MainActor
struct ClipboardNavigationDiagnosticsTests {
    static func main() async {
        var now = 10.0
        var samples: [ClipboardNavigationDiagnostics.Sample] = []
        let diagnostics = ClipboardNavigationDiagnostics(now: { now }, emit: { samples.append($0) })
        let first = diagnostics.beginInput(timestamp: 9.8, repeating: true)
        precondition(samples.last?.stage == .inputQueue)
        precondition(abs((samples.last?.milliseconds ?? 0) - 200) < 0.001)
        diagnostics.selected(id: "private-identity", index: 4, kind: .image, fileBacked: true)
        precondition(diagnostics.preview(for: "other") == nil)
        let preview = diagnostics.preview(for: "private-identity")
        precondition(preview?.sequence == first.sequence)
        now += 0.05
        diagnostics.finishDispatch(first)
        precondition(samples.last?.navigation.index == 4 && samples.last?.navigation.kind == .image)
        precondition(samples.last?.navigation.repeating == true)
        let count = samples.count
        diagnostics.scrolled()
        diagnostics.scrolled()
        precondition(samples.count == count + 1 && samples.last?.stage == .scroll)
        precondition(samples.allSatisfy { !$0.details.contains("private-identity") })
        diagnostics.record(.previewImage, milliseconds: 75, navigation: preview, outcome: .cancelled)
        precondition(samples.last?.outcome == .cancelled)
        let second = diagnostics.beginInput(timestamp: 0, repeating: false)
        precondition(second.sequence != first.sequence && samples.last?.milliseconds == 0)
        precondition(diagnostics.preview(for: "private-identity") == nil)
        diagnostics.stop()
        let stoppedCount = samples.count
        diagnostics.scrolled()
        try? await Task.sleep(for: .milliseconds(25))
        precondition(samples.count == stoppedCount)

        let measured = diagnostics.beginInput(timestamp: now, repeating: false)
        await Task.yield()
        now += 0.2
        for _ in 0..<20 {
            if samples.contains(where: { $0.stage == .mainActor && $0.navigation.sequence == measured.sequence }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let checkpoint = samples.last { $0.stage == .mainActor && $0.navigation.sequence == measured.sequence }
        precondition(abs((checkpoint?.milliseconds ?? 0) - 184) < 0.001)
        diagnostics.stop()

        precondition(ClipboardNavigationDiagnostics.Stage.previewWait.threshold.isInfinite)
        precondition(ClipboardNavigationDiagnostics.Stage.dispatch.threshold == 32)
        precondition(ClipboardNavigationDiagnostics.Stage.previewRead.threshold == 50)
        precondition(ClipboardNavigationDiagnostics.previewWorkMilliseconds(total: 350, waited: 300) == 50)
        precondition(ClipboardNavigationDiagnostics.previewWorkMilliseconds(total: 800, waited: 800) == 500)
        precondition(ClipboardNavigationDiagnostics.previewWorkMilliseconds(total: 50, waited: 50) == 0)
        precondition(ClipboardNavigationDiagnostics.previewWorkMilliseconds(total: 500, waited: 500) == 200)

        let iterations = 10_000
        let start = ContinuousClock.now
        let logger = Diagnostics(category: "clipboard-performance", publicBenchmarkDetails: true)
        for _ in 0..<iterations {
            logger.latency("clipboard.test", milliseconds: 1, threshold: 100, details: "")
        }
        let microseconds = Diagnostics.elapsedMilliseconds(since: start) * 1000 / Double(iterations)
        print("PASS: navigation correlation, event age, cancellation, bounded scroll reporting and private identities")
        print(String(format: "Fast timing log gate: %.2f microseconds/call (%d calls)", microseconds, iterations))
    }
}
