import AppKit
import ApplicationServices

@MainActor
final class WindowRegistry {
    var onSnapshotChanged: (() -> Void)?
    var onFocusedWindowObserved: ((pid_t, AXWindow) -> Void)?
    var onWindowDestroyed: ((pid_t, AXUIElement) -> Void)?
    var onCompleteWindowInventory: ((pid_t, [AXWindow], [AXWindow]) -> Void)?

    private let policy: WindowRegistryRefreshPolicy
    private let worker: AXWindowDiscoveryWorker
    private let cgSnapshots: CGWindowSnapshotCache
    private let workspaceCenter: NotificationCenter
    private let runningApplications: () -> [NSRunningApplication]
    private let frontmostApplication: () -> NSRunningApplication?
    private let isDiscoverable: (NSRunningApplication) -> Bool
    private let sortApplications: (NSRunningApplication, NSRunningApplication) -> Bool
    private let diagnostics = Diagnostics(category: "window-switcher")

    private var trackedApps: [pid_t: TrackedApp] = [:]
    private var appOrder: [pid_t: Int] = [:]
    private var cachedCGEntries: [CGWindowEntry] = []
    private var observers: [NSObjectProtocol] = []
    private lazy var refreshScheduler = WindowRefreshScheduler { [weak self] pid, request in
        await self?.reconcile(pid: pid, request: request)
    }
    private var registryGeneration = UUID()
    private lazy var reconciliationScheduler = WindowReconciliationScheduler { [weak self] request in
        await self?.reconcileAllApps(request: request)
    }
    private var periodicReconciliation: Task<Void, Never>?
    private var suppressIncrementalNotifications = false
    private var snapshotChangedWhileNotificationsWereSuppressed = false
    private var lastFailureLogDates: [pid_t: Date] = [:]
    private var refreshRequestCounts: [pid_t: Int] = [:]

    init(
        policy: WindowRegistryRefreshPolicy = WindowRegistryRefreshPolicy(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        runningApplications: @escaping () -> [NSRunningApplication] = { NSWorkspace.shared.runningApplications },
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        isDiscoverable: @escaping (NSRunningApplication) -> Bool,
        sortApplications: @escaping (NSRunningApplication, NSRunningApplication) -> Bool
    ) {
        let worker = AXWindowDiscoveryWorker()
        self.worker = worker
        let cgReader = CGWindowSnapshotReader()
        cgSnapshots = CGWindowSnapshotCache(read: { await cgReader.read() })
        self.policy = policy
        self.workspaceCenter = workspaceCenter
        self.runningApplications = runningApplications
        self.frontmostApplication = frontmostApplication
        self.isDiscoverable = isDiscoverable
        self.sortApplications = sortApplications
    }

    func start() {
        guard observers.isEmpty else {
            return
        }

        diagnostics.info("windowRegistry.start cacheFirst=true")
        observeWorkspaceApplications()
        synchronizeRunningApplications(scheduleNewAppRefresh: false)
        scheduleFullReconciliation(reason: .startup)
        startPeriodicReconciliation()
    }

    func stop() {
        registryGeneration = UUID()
        suppressIncrementalNotifications = false
        snapshotChangedWhileNotificationsWereSuppressed = false
        diagnostics.info("windowRegistry.stop")
        observers.forEach(workspaceCenter.removeObserver)
        observers.removeAll()
        refreshScheduler.cancelAll()
        cgSnapshots.reset()
        reconciliationScheduler.cancel()
        periodicReconciliation?.cancel()
        periodicReconciliation = nil
        refreshRequestCounts.removeAll()
        trackedApps.removeAll()
    }

    func snapshot(windowScope: WindowScope) -> WindowRegistrySnapshot {
        let frontmost = frontmostApplication()
        let frontmostPID = frontmost?.processIdentifier
        let apps = trackedApps.values
            .filter { isDiscoverable($0.runningApplication) }
            .filter {
                windowScope == .allApps || $0.runningApplication.processIdentifier == frontmostPID ||
                    SteamApplication.isSameApp(
                        frontmostBundleID: frontmost?.bundleIdentifier,
                        targetBundleID: $0.runningApplication.bundleIdentifier
                    )
            }
            .sorted { lhs, rhs in
                (appOrder[lhs.runningApplication.processIdentifier] ?? Int.max) <
                    (appOrder[rhs.runningApplication.processIdentifier] ?? Int.max)
            }
            .enumerated()
            .map { index, app in
                RegistryDiscoveredApp(
                    app: app.runningApplication,
                    appIndex: index,
                    windows: app.windows,
                    isHidden: app.runningApplication.isHidden
                )
            }

        return WindowRegistrySnapshot(
            apps: apps,
            cgEntries: cachedCGEntries,
            runningPIDs: Set(trackedApps.keys)
        )
    }

    func refreshAfterPanelOpen() {
        guard let pid = frontmostApplication()?.processIdentifier else {
            return
        }
        scheduleRefresh(pid: pid, reason: .panelOpened)
    }

    func refreshAll() {
        scheduleFullReconciliation(reason: .startup)
    }

    func setInteractionState(panelOpen: Bool, activationPending: Bool) {
        reconciliationScheduler.setInteractionState(panelOpen: panelOpen, activationPending: activationPending)
    }

    func refreshWindow(pid: pid_t, element: AXUIElement) async -> AXWindow? {
        guard let trackedApp = trackedApps[pid] else { return nil }
        cgSnapshots.invalidate()
        await refreshScheduler.refresh(pid: pid, request: WindowRefreshRequest(reason: .activationRequested))
        guard !Task.isCancelled,
              let current = trackedApps[pid], current.generation == trackedApp.generation else {
            return nil
        }
        if let exact = current.windows.first(where: { CFEqual($0.element, element) }) {
            return exact
        }
        return WindowReplacement.unambiguous(previous: trackedApp.windows, current: current.windows)
            .first { CFEqual($0.previous, element) }?.current
    }

    func cachedWindow(pid: pid_t) -> AXWindow? {
        guard let windows = trackedApps[pid]?.windows else {
            return nil
        }
        return AXWindow.preferredIndex(in: windows).map { windows[$0] }
    }

    private func observeWorkspaceApplications() {
        observe(NSWorkspace.didLaunchApplicationNotification) { registry, app in
            registry.upsert(app)
            registry.scheduleRefresh(pid: app.processIdentifier, reason: .appLaunched)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { registry, app in
            registry.removeApp(pid: app.processIdentifier)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { registry, app in
            registry.upsert(app)
            registry.scheduleRefresh(pid: app.processIdentifier, reason: .appActivated)
        }
        observe(NSWorkspace.didHideApplicationNotification) { registry, app in
            registry.upsert(app)
            registry.scheduleRefresh(pid: app.processIdentifier, reason: .appActivated)
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { registry, app in
            registry.upsert(app)
            registry.scheduleRefresh(pid: app.processIdentifier, reason: .appActivated)
        }

        let spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFullReconciliation(reason: .activeSpaceChanged)
            }
        }
        observers.append(spaceObserver)
    }

    private func synchronizeRunningApplications(scheduleNewAppRefresh: Bool = true) {
        let apps = runningApplications()
            .filter(isDiscoverable)
            .sorted(by: sortApplications)
        let currentPIDs = Set(apps.map(\.processIdentifier))

        for pid in trackedApps.keys where !currentPIDs.contains(pid) {
            removeApp(pid: pid)
        }

        for (index, app) in apps.enumerated() {
            appOrder[app.processIdentifier] = index
            if trackedApps[app.processIdentifier] == nil {
                trackedApps[app.processIdentifier] = TrackedApp(runningApplication: app)
                snapshotDidChange()
                if scheduleNewAppRefresh {
                    scheduleRefresh(pid: app.processIdentifier, reason: .appLaunched)
                }
            } else {
                trackedApps[app.processIdentifier]?.runningApplication = app
            }
        }
    }

    private func upsert(_ app: NSRunningApplication) {
        guard isDiscoverable(app) else {
            removeApp(pid: app.processIdentifier)
            return
        }

        let wasMissing = trackedApps[app.processIdentifier] == nil
        if wasMissing {
            trackedApps[app.processIdentifier] = TrackedApp(runningApplication: app)
        } else {
            trackedApps[app.processIdentifier]?.runningApplication = app
        }
        synchronizeApplicationOrder()
        if wasMissing {
            snapshotDidChange()
        }
    }

    private func synchronizeApplicationOrder() {
        let apps = trackedApps.values.map(\.runningApplication).sorted(by: sortApplications)
        for (index, app) in apps.enumerated() {
            appOrder[app.processIdentifier] = index
        }
    }

    private func scheduleRefresh(
        pid: pid_t,
        reason: WindowRegistryRefreshReason,
        element: AXUIElement? = nil,
        delayOverride: TimeInterval? = nil
    ) {
        guard trackedApps[pid] != nil else {
            return
        }
        refreshRequestCounts[pid, default: 0] += 1
        let request = WindowRefreshRequest(reason: reason, element: element)
        if request.requiresCGRefresh { cgSnapshots.invalidate() }

        refreshScheduler.schedule(
            pid: pid,
            request: request,
            delay: delayOverride ?? policy.coalescingInterval(for: reason)
        )
    }

    private func scheduleFullReconciliation(reason: WindowRegistryRefreshReason) {
        cgSnapshots.invalidate()
        reconciliationScheduler.schedule(reason)
    }

    private func startPeriodicReconciliation() {
        periodicReconciliation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                try? await Task.sleep(for: .seconds(self.policy.periodicReconciliationInterval))
                guard !Task.isCancelled else {
                    return
                }
                self.scheduleFullReconciliation(reason: .periodicReconciliation)
            }
        }
    }

    private func reconcileAllApps(request: WindowRefreshRequest) async {
        let generation = registryGeneration
        let benchmarkStart = ContinuousClock.now
        var cgMilliseconds = 0.0
        suppressIncrementalNotifications = true
        snapshotChangedWhileNotificationsWereSuppressed = false
        defer {
            diagnostics.benchmark(
                "windowRegistry.reconcileAll",
                since: benchmarkStart,
                details: "reason=\(request.benchmarkName) apps=\(trackedApps.count) cg_ms=\(Self.benchmarkNumber(cgMilliseconds))"
            )
            if registryGeneration == generation {
                suppressIncrementalNotifications = false
                snapshotChangedWhileNotificationsWereSuppressed = false
            }
        }

        synchronizeRunningApplications(scheduleNewAppRefresh: false)
        let cgStart = ContinuousClock.now
        let cgEntries = await cgSnapshots.snapshot()
        cgMilliseconds = Diagnostics.elapsedMilliseconds(since: cgStart)
        guard !Task.isCancelled, registryGeneration == generation else { return }
        updateCGEntries(cgEntries)
        let pids = trackedApps.keys.sorted {
            (appOrder[$0] ?? Int.max) < (appOrder[$1] ?? Int.max)
        }
        diagnostics.info("windowRegistry.reconcileAll reason=\(request.benchmarkName) apps=\(pids.count)")

        for pid in pids where !Task.isCancelled {
            await refreshScheduler.refresh(pid: pid, request: request)
        }
        if registryGeneration == generation, snapshotChangedWhileNotificationsWereSuppressed {
            suppressIncrementalNotifications = false
            onSnapshotChanged?()
        }
    }

    private func reconcile(pid: pid_t, request: WindowRefreshRequest) async {
        guard let generation = trackedApps[pid]?.generation else { return }
        let benchmarkStart = ContinuousClock.now
        let requestCount = refreshRequestCounts.removeValue(forKey: pid) ?? 0
        let coalescedCount = max(0, requestCount - 1)
        let source = request.requiresCGRefresh ? "incremental" : (request.reasons == [.windowTitleChanged] ? "cached" : "full")
        var cgMilliseconds = 0.0
        var readMilliseconds = 0.0
        var applyMilliseconds = 0.0
        var observerMilliseconds = 0.0
        var outcome = "incomplete"
        var windowCount = 0
        defer {
            diagnostics.benchmark(
                "windowRegistry.reconcile",
                since: benchmarkStart,
                details: "pid=\(pid) reason=\(request.benchmarkName) source=\(source) requests=\(requestCount) coalesced=\(coalescedCount) overlap_depth=1 cg_ms=\(Self.benchmarkNumber(cgMilliseconds)) read_ms=\(Self.benchmarkNumber(readMilliseconds)) apply_ms=\(Self.benchmarkNumber(applyMilliseconds)) observer_ms=\(Self.benchmarkNumber(observerMilliseconds)) outcome=\(outcome) windows=\(windowCount)"
            )
        }
        if request.startsFreshRetrySequence {
            trackedApps[pid]?.consecutiveFailures = 0
            trackedApps[pid]?.consecutiveObserverFailures = 0
        }
        if request.requiresCGRefresh {
            let cgStart = ContinuousClock.now
            let entries = await cgSnapshots.snapshot()
            cgMilliseconds = Diagnostics.elapsedMilliseconds(since: cgStart)
            guard trackedApps[pid]?.generation == generation else { return }
            updateCGEntries(entries)
        }
        let cgEntries = cachedCGEntries
        let windowRevision = trackedApps[pid]?.windowRevision
        let readStart = ContinuousClock.now
        let result = await worker.readWindows(
            pid: pid,
            cgEntries: cgEntries,
            request: request,
            previousWindows: trackedApps[pid]?.windows ?? [],
            allowUnknownWindows: trackedApps[pid].flatMap { WineApplication.wrapperURL(for: $0.runningApplication) } != nil
        )
        readMilliseconds = Diagnostics.elapsedMilliseconds(since: readStart)
        outcome = result.benchmarkOutcome
        windowCount = result.windowCount
        guard trackedApps[pid]?.generation == generation,
              trackedApps[pid]?.windowRevision == windowRevision else { return }

        let applyStart = ContinuousClock.now
        let windowsForObservation = apply(result, pid: pid, request: request)
        if (!result.isIncremental || request.updatesFocus), let focusedWindow = result.focusedWindow {
            onFocusedWindowObserved?(pid, focusedWindow)
        }
        applyMilliseconds = Diagnostics.elapsedMilliseconds(since: applyStart)
        let observerStart = ContinuousClock.now
        if !result.isIncremental || trackedApps[pid]?.observer == nil {
            await ensureObserver(pid: pid, windows: windowsForObservation)
        }
        observerMilliseconds = Diagnostics.elapsedMilliseconds(since: observerStart)
    }

    private func apply(
        _ result: AXAppWindowReadResult,
        pid: pid_t,
        request: WindowRefreshRequest
    ) -> [AXWindow] {
        guard var trackedApp = trackedApps[pid] else {
            return []
        }

        let previousWindows = trackedApp.windows
        switch result {
        case .updated(let windows):
            trackedApp.windows = windows
            trackedApps[pid] = trackedApp

        case .success(let windows):
            if windows.isEmpty && !previousWindows.isEmpty && trackedApp.consecutiveEmptyReads == 0 {
                trackedApp.consecutiveEmptyReads = 1
                trackedApps[pid] = trackedApp
                scheduleRefresh(pid: pid, reason: .retryAfterFailure)
                return previousWindows
            }

            trackedApp.windows = windows
            onCompleteWindowInventory?(pid, previousWindows, windows)
            trackedApp.consecutiveEmptyReads = windows.isEmpty ? trackedApp.consecutiveEmptyReads + 1 : 0
            trackedApp.consecutiveFailures = 0
            trackedApps[pid] = trackedApp

        case .partial(let windows, let error):
            trackedApp.windows = AXWindow.merging(previousWindows, with: windows)
            trackedApp.consecutiveEmptyReads = 0
            trackedApp.consecutiveFailures += 1
            trackedApps[pid] = trackedApp
            logFailure(pid: pid, message: "partial reason=\(request.benchmarkName) error=\(error.rawValue)")
            scheduleRetryIfNeeded(pid: pid, error: error)

        case .failure(let error):
            trackedApp.consecutiveFailures += 1
            trackedApps[pid] = trackedApp
            logFailure(pid: pid, message: "failed reason=\(request.benchmarkName) error=\(error.rawValue)")
            scheduleRetryIfNeeded(pid: pid, error: error)
        }

        let currentWindows = trackedApps[pid]?.windows ?? previousWindows
        if !windowsAreEqual(previousWindows, currentWindows) {
            snapshotDidChange()
        }
        return currentWindows
    }

    private func scheduleRetryIfNeeded(pid: pid_t, error: AXError) {
        guard error != .apiDisabled, let failureCount = trackedApps[pid]?.consecutiveFailures else {
            return
        }
        guard let interval = policy.retryInterval(afterFailureCount: failureCount) else {
            diagnostics.warning("windowRegistry.retry stopped", details: "pid=\(pid) failures=\(failureCount)")
            return
        }
        scheduleRefresh(pid: pid, reason: .retryAfterFailure, delayOverride: interval)
    }

    private func ensureObserver(pid: pid_t, windows: [AXWindow]) async {
        guard let trackedApp = trackedApps[pid] else {
            return
        }

        let generation = trackedApp.generation
        if let observer = trackedApp.observer {
            await worker.updateObserver(observer, pid: pid, windows: windows)
            guard trackedApps[pid]?.generation == generation else { return }
            trackedApps[pid]?.consecutiveObserverFailures = 0
            return
        }

        let callback: @Sendable (AXRegistryEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard self?.trackedApps[pid]?.generation == generation else { return }
                self?.handle(event, pid: pid)
            }
        }
        let observer = await worker.makeObserver(pid: pid, windows: windows, callback: callback)
        guard trackedApps[pid]?.generation == generation else { return }
        guard let observer else {
            scheduleObserverRetryIfNeeded(pid: pid)
            return
        }
        if trackedApps[pid]?.observer == nil {
            trackedApps[pid]?.observer = observer
        }
        trackedApps[pid]?.consecutiveObserverFailures = 0
    }

    private func scheduleObserverRetryIfNeeded(pid: pid_t) {
        guard var trackedApp = trackedApps[pid] else {
            return
        }

        trackedApp.consecutiveObserverFailures += 1
        let failureCount = trackedApp.consecutiveObserverFailures
        trackedApps[pid] = trackedApp
        logFailure(pid: pid, message: "observer failed failures=\(failureCount)")

        guard let interval = policy.retryInterval(afterFailureCount: failureCount) else {
            diagnostics.warning("windowRegistry.observerRetry stopped", details: "pid=\(pid) failures=\(failureCount)")
            return
        }
        scheduleRefresh(pid: pid, reason: .retryAfterFailure, delayOverride: interval)
    }

    private func handle(_ event: AXRegistryEvent, pid: pid_t) {
        guard trackedApps[pid] != nil else {
            return
        }
        if event.refreshReason == .windowDestroyed {
            trackedApps[pid]?.windowRevision += 1
            trackedApps[pid]?.windows.removeAll { CFEqual($0.element, event.element) }
            onWindowDestroyed?(pid, event.element)
            snapshotDidChange()
        }
        scheduleRefresh(pid: pid, reason: event.refreshReason, element: event.element)
    }

    private func updateCGEntries(_ entries: [CGWindowEntry]) {
        guard cachedCGEntries != entries else {
            return
        }
        cachedCGEntries = entries
        snapshotDidChange()
    }

    private func removeApp(pid: pid_t) {
        guard trackedApps.removeValue(forKey: pid) != nil else {
            return
        }
        appOrder.removeValue(forKey: pid)
        refreshScheduler.cancel(pid: pid)
        lastFailureLogDates.removeValue(forKey: pid)
        refreshRequestCounts.removeValue(forKey: pid)
        snapshotDidChange()
    }

    private func snapshotDidChange() {
        if suppressIncrementalNotifications {
            snapshotChangedWhileNotificationsWereSuppressed = true
        } else {
            onSnapshotChanged?()
        }
    }

    private func windowsAreEqual(_ lhs: [AXWindow], _ rhs: [AXWindow]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { left, right in
            CFEqual(left.element, right.element) &&
                left.title == right.title &&
                left.frame == right.frame &&
                left.isMinimized == right.isMinimized &&
                left.isMain == right.isMain &&
                left.isFocused == right.isFocused
        }
    }

    private func logFailure(pid: pid_t, message: String) {
        let now = Date()
        if let previous = lastFailureLogDates[pid], now.timeIntervalSince(previous) < 2 {
            return
        }
        lastFailureLogDates[pid] = now
        diagnostics.info("windowRegistry.reconcile pid=\(pid) \(message)")
    }

    private static func benchmarkNumber(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor @Sendable (WindowRegistry, NSRunningApplication) -> Void
    ) {
        let observer = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                handler(self, app)
            }
        }
        observers.append(observer)
    }
}

struct WindowRegistrySnapshot {
    let apps: [RegistryDiscoveredApp]
    let cgEntries: [CGWindowEntry]
    let runningPIDs: Set<pid_t>
}

struct RegistryDiscoveredApp {
    let app: NSRunningApplication
    let appIndex: Int
    let windows: [AXWindow]
    let isHidden: Bool
}

private struct TrackedApp {
    let generation = UUID()
    var runningApplication: NSRunningApplication
    var windows: [AXWindow] = []
    var windowRevision = 0
    var observer: AXObserverController?
    var consecutiveEmptyReads = 0
    var consecutiveFailures = 0
    var consecutiveObserverFailures = 0
}

enum AXAppWindowReadResult: @unchecked Sendable {
    case success([AXWindow])
    case updated([AXWindow])
    case partial([AXWindow], AXError)
    case failure(AXError)

    var focusedWindow: AXWindow? {
        switch self {
        case .success(let windows), .updated(let windows):
            AXWindow.preferredIndex(in: windows).map { windows[$0] }
        case .partial(let windows, _):
            windows.first(where: \.isFocused)
        case .failure:
            nil
        }
    }

    var benchmarkOutcome: String {
        switch self {
        case .success:
            "success"
        case .updated:
            "updated"
        case .partial(_, let error):
            "partial_\(error.rawValue)"
        case .failure(let error):
            "failure_\(error.rawValue)"
        }
    }

    var windowCount: Int {
        switch self {
        case .success(let windows), .updated(let windows), .partial(let windows, _):
            windows.count
        case .failure:
            0
        }
    }

    var isIncremental: Bool {
        if case .updated = self { return true }
        return false
    }
}

private struct AXWindowDiscoveryWorker: Sendable {
    private let lock = NSLock()
    private let diagnostics = Diagnostics(category: "window-switcher")
    private let inventoryReader = AXWindowInventoryReader()

    func readWindows(
        pid: pid_t,
        cgEntries: [CGWindowEntry],
        request: WindowRefreshRequest,
        previousWindows: [AXWindow],
        allowUnknownWindows: Bool
    ) async -> AXAppWindowReadResult {
        return await run(pid: pid) { [self] in

        diagnostics.measure("windowRegistry.readWindows pid=\(pid)", thresholdMilliseconds: 20) {
            inventoryReader.read(
                pid: pid, cgEntries: cgEntries, request: request,
                previousWindows: previousWindows, allowUnknownWindows: allowUnknownWindows
            )
        }

        }
    }

    func makeObserver(
        pid: pid_t,
        windows: [AXWindow],
        callback: @escaping @Sendable (AXRegistryEvent) -> Void
    ) async -> AXObserverController? {
        return await run(pid: pid) { [self] in

        guard let observer = AXObserverController(pid: pid, callback: callback) else {
            return nil
        }
        configure(observer, pid: pid, windows: windows)
        return observer

        }
    }

    func updateObserver(_ observer: AXObserverController, pid: pid_t, windows: [AXWindow]) async {
        await run(pid: pid) { [self] in

        configure(observer, pid: pid, windows: windows)

        }
    }

    private func run<T: Sendable>(pid: pid_t, _ operation: @escaping @Sendable () -> T) async -> T {
        if pid == getpid() { return await MainActor.run(body: operation) }
        let task = Task.detached(priority: .utility) { [lock] in lock.withLock(operation) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func configure(_ observer: AXObserverController, pid: pid_t, windows: [AXWindow]) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AXWindowReader.defaultMessagingTimeout)
        observer.observe(
            element: appElement,
            notifications: [
                kAXWindowCreatedNotification,
                kAXFocusedWindowChangedNotification,
                kAXMainWindowChangedNotification,
            ]
        )
        for window in windows {
            AXUIElementSetMessagingTimeout(window.element, AXWindowReader.defaultMessagingTimeout)
            observer.observe(
                element: window.element,
                notifications: [
                    kAXUIElementDestroyedNotification,
                    kAXTitleChangedNotification,
                    kAXMovedNotification,
                    kAXResizedNotification,
                    kAXWindowMiniaturizedNotification,
                    kAXWindowDeminiaturizedNotification,
                ]
            )
        }
    }
}

private struct AXRegistryEvent: @unchecked Sendable {
    let element: AXUIElement
    let notification: String

    var refreshReason: WindowRegistryRefreshReason {
        switch notification {
        case String(kAXTitleChangedNotification):
            return .windowTitleChanged
        case String(kAXMovedNotification), String(kAXResizedNotification):
            return .windowMovedOrResized
        case String(kAXWindowMiniaturizedNotification), String(kAXWindowDeminiaturizedNotification):
            return .windowMinimizedStateChanged
        case String(kAXWindowCreatedNotification):
            return .windowCreated
        case String(kAXUIElementDestroyedNotification):
            return .windowDestroyed
        case String(kAXFocusedWindowChangedNotification), String(kAXMainWindowChangedNotification):
            return .windowFocusChanged
        default:
            return .appActivated
        }
    }
}

private final class AXObserverController: @unchecked Sendable {
    private struct Registration {
        let element: AXUIElement
        let notification: String
    }

    private let observer: AXObserver
    private let callback: @Sendable (AXRegistryEvent) -> Void
    private let lock = NSLock()
    private var registrations: [Registration] = []

    init?(pid: pid_t, callback: @escaping @Sendable (AXRegistryEvent) -> Void) {
        var observer: AXObserver?
        let result = AXObserverCreate(
            pid,
            { _, element, notificationName, refcon in
                guard let refcon else {
                    return
                }
                let controller = Unmanaged<AXObserverController>.fromOpaque(refcon).takeUnretainedValue()
                if notificationName as String == String(kAXUIElementDestroyedNotification) {
                    controller.forgetRegistrations(for: element)
                }
                controller.callback(
                    AXRegistryEvent(element: element, notification: notificationName as String)
                )
            },
            &observer
        )
        guard result == .success, let observer else {
            return nil
        }

        self.observer = observer
        self.callback = callback
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func observe(element: AXUIElement, notifications: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            let alreadyRegistered = registrations.contains {
                $0.notification == notification && CFEqual($0.element, element)
            }
            guard !alreadyRegistered else {
                continue
            }

            let result = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                registrations.append(Registration(element: element, notification: notification))
            }
        }
    }

    private func forgetRegistrations(for element: AXUIElement) {
        lock.lock()
        registrations.removeAll { CFEqual($0.element, element) }
        lock.unlock()
    }
}
