import AppKit
import Foundation

enum Paster { static let ollieEventTag: Int64 = 0x465245444945 }

private final class FocusGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0
    private var mainThreadCalls = 0
    var count: Int { lock.withLock { calls } }
    var blockedMainThread: Bool { lock.withLock { mainThreadCalls > 0 } }
    func call() {
        lock.withLock { calls += 1; if Thread.isMainThread { mainThreadCalls += 1 } }
        _ = release.wait(timeout: .now() + 2)
    }
    func finish() { release.signal() }
}

@MainActor
private final class SnapshotGate {
    var calls = 0
    var waiters: [CheckedContinuation<[CGWindowEntry], Never>] = []
    func read() async -> [CGWindowEntry] {
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func finish(order: Int, index: Int = 0) {
        waiters.remove(at: index).resume(returning: [CGWindowEntry(order: order, pid: 1, title: nil, bounds: .zero, layer: 0, isOnScreen: true)])
    }
}

@MainActor
private final class RefreshGate {
    var requests: [WindowRefreshRequest] = []
    var active = 0
    var peak = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    func run(_ request: WindowRefreshRequest) async {
        requests.append(request)
        active += 1
        peak = max(peak, active)
        await withCheckedContinuation { waiters.append($0) }
        active -= 1
    }
    func finish() { waiters.removeFirst().resume() }
}

@main
@MainActor
struct OllieSwitcherTests {
    private static var failures = 0

    static func main() async throws {
        let focusGate = FocusGate()
        let worker = AXFocusWorker(action: { _, _ in focusGate.call(); return .success })
        let target = AXWindowTarget(pid: 1, element: AXUIElementCreateApplication(1))
        let first = Task { await worker.perform(.raise, target: target) }
        try await wait { focusGate.count == 1 }
        check("accessibility work leaves main actor available", !focusGate.blockedMainThread)
        let cancelled = Task { await worker.perform(.focus, target: target) }
        await Task.yield()
        cancelled.cancel()
        focusGate.finish()
        check("first focus action completes", await first.value == .success)
        check("cancelled queued focus never reaches AX", await cancelled.value == .cannotComplete && focusGate.count == 1)

        let localWorker = AXFocusWorker(
            action: { _, _ in Thread.isMainThread ? .success : .cannotComplete },
            focused: { _ in Thread.isMainThread }
        )
        let localTarget = AXWindowTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()))
        for action in [AXWindowAction.unminimize, .raise, .makeMain, .focus, .close] {
            check("own window actions use AppKit's main thread", await localWorker.perform(action, target: localTarget) == .success)
        }
        check("own window focus reads use the main thread", await localWorker.isFocused(localTarget))
        check("own window closes use the main thread", await localWorker.closeWindow(pid: getpid(), target: localTarget) == .success)

        let snapshotGate = SnapshotGate()
        let cache = CGWindowSnapshotCache { await snapshotGate.read() }
        let reads = (0..<20).map { _ in Task { await cache.snapshot() } }
        try await wait { snapshotGate.calls == 1 }
        snapshotGate.finish(order: 1)
        for read in reads { check("shared scan result", await read.value.first?.order == 1) }
        check("burst performs one OS scan", snapshotGate.calls == 1)
        cache.invalidate()
        let old = Task { await cache.snapshot() }
        try await wait { snapshotGate.calls == 2 }
        cache.reset()
        let current = Task { await cache.snapshot() }
        try await wait { snapshotGate.calls == 3 }
        snapshotGate.finish(order: 3, index: 1)
        check("new generation resolves", await current.value.first?.order == 3)
        snapshotGate.finish(order: 2)
        check("late old generation is discarded", await old.value.isEmpty)
        check("late old scan cannot replace cache", await cache.snapshot().first?.order == 3)

        let refresh = RefreshGate()
        let scheduler = WindowRefreshScheduler { _, request in await refresh.run(request) }
        scheduler.schedule(pid: 1, request: WindowRefreshRequest(reason: .windowTitleChanged), delay: 0)
        try await wait { refresh.requests.count == 1 }
        for _ in 0..<20 { scheduler.schedule(pid: 1, request: WindowRefreshRequest(reason: .windowMovedOrResized), delay: 0) }
        scheduler.cancel(pid: 1)
        scheduler.schedule(pid: 1, request: WindowRefreshRequest(reason: .appLaunched), delay: 0)
        refresh.finish()
        try await wait { refresh.requests.count == 2 }
        check("cancellation discards old pending inventory", refresh.requests[1].reasons == [.appLaunched])
        check("per-app reads remain serial", refresh.peak == 1)
        refresh.finish()
        scheduler.cancel(pid: 1)

        let displays = [DisplaySpaces(identifier: "left", current: 2, spaces: [1, 2, 3]), DisplaySpaces(identifier: "right", current: 10, spaces: [10, 42, 99])]
        check("full-screen target uses its own display", SpaceSwitchPlan.make(windowSpaces: [99], displays: displays) == SpaceSwitchPlan(display: "right", target: 99, steps: 2))
        check("visible windows do not change spaces", SpaceSwitchPlan.make(windowSpaces: [2], displays: displays) == nil)
        check("unknown window does not guess a space", SpaceSwitchPlan.make(windowSpaces: [], displays: displays) == nil)
        print(failures == 0 ? "Window switcher integration passed" : "\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<300 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "Switcher fixture timed out", code: 1)
    }

    private static func check(_ name: String, _ value: Bool) {
        if !value { failures += 1; print("FAIL: \(name)") }
    }
}
