import AppKit
import ApplicationServices

@MainActor
final class WindowDiscovery {
    var onInventoryChanged: (() -> Void)?

    private var iconCache: [pid_t: NSImage] = [:]
    private var activationHistory = WindowActivationHistory()
    private var isPreviewing = false
    private var accessibilityTrustTask: Task<Void, Never>?
    private let profiler = WindowDiscoveryProfiler()
    private lazy var windowRegistry = WindowRegistry(
        isDiscoverable: { [weak self] app in
            self?.isDiscoverable(app) ?? false
        },
        sortApplications: { [weak self] lhs, rhs in
            self?.sortApplications(lhs, rhs) ?? false
        }
    )

    func startRegistry() {
        windowRegistry.onSnapshotChanged = { [weak self] in
            self?.onInventoryChanged?()
        }
        windowRegistry.onFocusedWindowObserved = { [weak self] pid, window in
            guard self?.isPreviewing == false,
                  pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                return
            }
            self?.activationHistory.observeFocus(pid: pid, window: window)
        }
        windowRegistry.onWindowDestroyed = { [weak self] pid, element in
            self?.activationHistory.remove(pid: pid, element: element)
        }
        windowRegistry.onCompleteWindowInventory = { [weak self] pid, previous, windows in
            self?.activationHistory.reconcile(pid: pid, previous: previous, current: windows)
        }
        prewarmIcons()
        windowRegistry.start()
    }

    func stopRegistry() {
        accessibilityTrustTask?.cancel()
        accessibilityTrustTask = nil
        windowRegistry.stop()
    }

    func refreshAfterPanelOpen() {
        windowRegistry.refreshAfterPanelOpen()
    }

    func refreshTarget(_ item: SwitcherItem) async -> SwitcherItem? {
        let app = item.runningApplication
        guard !app.isTerminated else { return nil }
        guard let element = item.windowElement else { return item.kind == .appOnly ? item : nil }
        guard let window = await windowRegistry.refreshWindow(pid: app.processIdentifier, element: element) else {
            return nil
        }
        return SwitcherItem(
            kind: .window,
            appName: item.appName,
            windowTitle: window.title,
            displayTitle: window.title?.isEmpty == false ? window.title! : item.appName,
            appIcon: item.appIcon,
            runningApplication: app,
            windowElement: window.element,
            windowFrame: window.frame,
            displayID: displayID(for: window.frame),
            isHidden: app.isHidden,
            isMinimized: window.isMinimized
        )
    }

    func requestAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(options) else {
            return
        }

        accessibilityTrustTask?.cancel()
        accessibilityTrustTask = Task { [weak self] in
            while !Task.isCancelled && !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else {
                return
            }
            self.accessibilityTrustTask = nil
            self.windowRegistry.refreshAll()
        }
    }

    func recordActivation(of app: NSRunningApplication?) {
        guard !isPreviewing, let app, isDiscoverable(app) else {
            return
        }

        activationHistory.recordApplicationActivation(pid: app.processIdentifier)
    }

    func beginActivation(of item: SwitcherItem) -> Int? {
        guard !isPreviewing else { return nil }
        let pid = item.runningApplication.processIdentifier
        guard let window = item.axWindow else { return nil }

        if
            pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let currentWindow = windowRegistry.cachedWindow(pid: pid)
        {
            activationHistory.observeFocus(pid: pid, window: currentWindow)
        }

        return activationHistory.recordExplicitActivation(pid: pid, window: window)
    }

    func finishActivation(of item: SwitcherItem, order: Int?, activated: SwitcherItem?) {
        if activated == nil, let order {
            activationHistory.cancelActivation(pid: item.runningApplication.processIdentifier, order: order)
        }
        guard !isPreviewing else { return }
        if let activated {
            let pid = activated.runningApplication.processIdentifier
            if let window = activated.axWindow {
                activationHistory.observeFocus(pid: pid, window: window)
            } else {
                activationHistory.recordApplicationActivation(pid: pid)
            }
        }
    }

    func beginPreview(from item: SwitcherItem?) {
        if let item, let window = item.axWindow {
            activationHistory.observeFocus(pid: item.runningApplication.processIdentifier, window: window)
        }
        isPreviewing = true
    }

    func endPreview() {
        isPreviewing = false
    }

    func setInteractionState(panelOpen: Bool, activationPending: Bool) {
        windowRegistry.setInteractionState(panelOpen: panelOpen, activationPending: activationPending)
    }

    func snapshot(settings: SwitcherSettings, windowScope: WindowScope = .allApps) -> [SwitcherItem] {
        profiler.beginSnapshot()
        let items = profiler.measure("snapshot") {
            let context = profiler.measure("snapshot.context") {
                makeSnapshotContext(settings: settings, windowScope: windowScope)
            }
            let rankedItems = profiler.measure("snapshot.ranking") {
                context.discoveredApps.flatMap { app in
                    makeRankedItems(for: app, context: context)
                }
            }

            return profiler.measure("snapshot.sort") {
                sortedItems(from: rankedItems, frontmostPID: context.frontmostPID)
            }
        }
        profiler.finishSnapshot(itemCount: items.count)
        return items
    }

    private func makeSnapshotContext(settings: SwitcherSettings, windowScope: WindowScope) -> SnapshotContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let registrySnapshot = profiler.measure("snapshot.cachedRegistry") {
            windowRegistry.snapshot(windowScope: windowScope)
        }
        let discoveredApps = registrySnapshot.apps
        profiler.measure("snapshot.pruneActivationState") {
            pruneActivationOrder(keeping: registrySnapshot.runningPIDs)
        }
        let activationRecordsByPID = profiler.measure("snapshot.activationRecordIndex") {
            Dictionary(grouping: activationHistory.records, by: \.pid)
        }
        return SnapshotContext(
            settings: settings,
            discoveredApps: discoveredApps,
            frontmostPID: frontmost?.processIdentifier,
            frontmostBundleID: frontmost?.bundleIdentifier,
            windowActivationRecordsByPID: activationRecordsByPID,
            windowOrdering: WindowOrdering(entries: registrySnapshot.cgEntries)
        )
    }

    private func makeRankedItems(for discoveredApp: RegistryDiscoveredApp, context: SnapshotContext) -> [RankedSwitcherItem] {
        let frontmostWindowIndex = frontmostWindowIndex(for: discoveredApp, context: context)

        if discoveredApp.windows.isEmpty {
            if discoveredApp.app.processIdentifier == getpid() ||
                WineApplication.wrapperURL(for: discoveredApp.app) != nil ||
                SteamApplication.isSteamHelper(discoveredApp.app.bundleIdentifier) ||
                (discoveredApp.app.bundleIdentifier == SteamApplication.bundleID &&
                    context.discoveredApps.contains { SteamApplication.isSteamHelper($0.app.bundleIdentifier) && !$0.windows.isEmpty }) {
                return []
            }
            return rankedAppOnlyItems(for: discoveredApp, context: context)
        }

        let windowMatches = context.windowOrdering.matches(
            pid: discoveredApp.app.processIdentifier,
            windows: discoveredApp.windows
        )
        return discoveredApp.windows.enumerated().compactMap { windowIndex, window in
            rankedWindowItem(
                for: DiscoveredWindow(
                    app: discoveredApp,
                    window: window,
                    windowIndex: windowIndex
                ),
                isFrontmostItem: windowIndex == frontmostWindowIndex,
                windowMatch: WindowMatch(entry: windowMatches[windowIndex]),
                context: context
            )
        }
    }

    private func frontmostWindowIndex(for discoveredApp: RegistryDiscoveredApp, context: SnapshotContext) -> Int? {
        guard discoveredApp.app.processIdentifier == context.frontmostPID || SteamApplication.isSameApp(
            frontmostBundleID: context.frontmostBundleID,
            targetBundleID: discoveredApp.app.bundleIdentifier
        ) else {
            return nil
        }

        return AXWindow.preferredIndex(in: discoveredApp.windows)
    }

    private func rankedAppOnlyItems(for discoveredApp: RegistryDiscoveredApp, context: SnapshotContext) -> [RankedSwitcherItem] {
        let destination = DiscoveryItemPlacement.destinationForAppOnly(settings: context.settings)
        guard destination != .excluded else {
            return []
        }

        let app = discoveredApp.app
        let item = SwitcherItem(
            kind: .appOnly,
            appName: app.localizedName ?? "Unknown App",
            windowTitle: nil,
            displayTitle: app.localizedName ?? "Unknown App",
            appIcon: icon(for: app),
            runningApplication: app,
            windowElement: nil,
            windowFrame: nil,
            displayID: nil,
            isHidden: discoveredApp.isHidden,
            isMinimized: false
        )
        return [
            RankedSwitcherItem(
                item: item,
                destination: destination,
                sortGroup: .appOnly,
                cgOrder: nil,
                activationOrder: activationHistory.appOrder(for: app.processIdentifier),
                appOrder: discoveredApp.appIndex,
                itemOrder: 0,
                windowPriority: 0,
                isFrontmostItem: app.processIdentifier == context.frontmostPID
            ),
        ]
    }

    private func rankedWindowItem(
        for discoveredWindow: DiscoveredWindow,
        isFrontmostItem: Bool,
        windowMatch: WindowMatch,
        context: SnapshotContext
    ) -> RankedSwitcherItem? {
        let app = discoveredWindow.app.app
        let window = discoveredWindow.window
        let visibility = visibility(
            app: app,
            window: window,
            windowMatch: windowMatch.entry,
            settings: context.settings
        )

        guard visibility.shouldInclude else {
            return nil
        }

        let destination = DiscoveryItemPlacement.destinationForWindow(
            isHidden: discoveredWindow.app.isHidden,
            isMinimized: window.isMinimized,
            settings: context.settings
        )
        guard destination != .excluded else {
            return nil
        }

        let appName: String
        if let wrapperURL = WineApplication.wrapperURL(for: app) {
            appName = (Bundle(url: wrapperURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? wrapperURL.deletingPathExtension().lastPathComponent
        } else {
            appName = SteamApplication.isSteamHelper(app.bundleIdentifier) ? "Steam" : (app.localizedName ?? "Unknown App")
        }
        let title = window.title?.isEmpty == false ? window.title! : appName
        let item = SwitcherItem(
            kind: .window,
            appName: appName,
            windowTitle: window.title,
            displayTitle: title,
            appIcon: icon(for: app),
            runningApplication: app,
            windowElement: window.element,
            windowFrame: window.frame,
            displayID: displayID(for: windowMatch.entry?.bounds ?? window.frame),
            isHidden: discoveredWindow.app.isHidden,
            isMinimized: window.isMinimized
        )
        return RankedSwitcherItem(
            item: item,
            destination: destination,
            sortGroup: visibility.sortGroup,
            cgOrder: windowMatch.cgOrder,
            activationOrder: windowActivationOrder(app: app, window: window, context: context),
            appOrder: discoveredWindow.app.appIndex,
            itemOrder: discoveredWindow.windowIndex,
            windowPriority: window.sortPriority,
            isFrontmostItem: isFrontmostItem
        )
    }

    private func sortedItems(from rankedItems: [RankedSwitcherItem], frontmostPID: pid_t?) -> [SwitcherItem] {
        var primaryItems: [RankedSwitcherItem] = []
        var bottomItems: [RankedSwitcherItem] = []
        primaryItems.reserveCapacity(rankedItems.count)
        bottomItems.reserveCapacity(rankedItems.count)

        for rankedItem in rankedItems {
            switch rankedItem.destination {
            case .primary:
                primaryItems.append(rankedItem)
            case .bottom:
                bottomItems.append(rankedItem)
            case .excluded:
                break
            }
        }

        primaryItems.sort(by: compareRankedItems)
        bottomItems.sort(by: compareRankedItems)

        var sortedItems = primaryItems + bottomItems
        if !SwitcherItemOrdering.moveFirstMatchToFront(&sortedItems, isMatch: \.isFrontmostItem), let frontmostPID {
            SwitcherItemOrdering.moveFirstMatchToFront(&sortedItems) { item in
                item.item.runningApplication.processIdentifier == frontmostPID
            }
        }

        return sortedItems.map(\.item)
    }

    private func isDiscoverable(_ app: NSRunningApplication) -> Bool {
        (app.activationPolicy == .regular ||
            (SteamApplication.isSteamHelper(app.bundleIdentifier) && app.activationPolicy == .accessory)) &&
            !app.isTerminated
    }

    private func displayID(for frame: CGRect?) -> CGDirectDisplayID? {
        guard let frame, !frame.isEmpty else {
            return nil
        }

        var displayID = CGDirectDisplayID()
        var displayCount: UInt32 = 0
        let result = CGGetDisplaysWithRect(frame, 1, &displayID, &displayCount)
        return result == .success && displayCount > 0 ? displayID : nil
    }

    private func pruneActivationOrder(keeping runningPIDs: Set<pid_t>) {
        activationHistory.prune(keeping: runningPIDs)
        iconCache = iconCache.filter { runningPIDs.contains($0.key) }
    }

    private func sortApplications(_ lhs: NSRunningApplication, _ rhs: NSRunningApplication) -> Bool {
        if lhs.isActive != rhs.isActive {
            return lhs.isActive
        }

        let leftActivationOrder = activationHistory.appOrder(for: lhs.processIdentifier)
        let rightActivationOrder = activationHistory.appOrder(for: rhs.processIdentifier)
        if leftActivationOrder != rightActivationOrder {
            return leftActivationOrder > rightActivationOrder
        }

        let leftDate = lhs.launchDate ?? .distantPast
        let rightDate = rhs.launchDate ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }

        return (lhs.localizedName ?? "") < (rhs.localizedName ?? "")
    }

    private func icon(for app: NSRunningApplication) -> NSImage? {
        if let image = iconCache[app.processIdentifier] {
            return image
        }

        let icon: NSImage?
        if let wrapperURL = WineApplication.wrapperURL(for: app) {
            icon = NSWorkspace.shared.icon(forFile: wrapperURL.path)
        } else {
            icon = app.icon
        }
        guard let icon else {
            return nil
        }

        icon.size = NSSize(width: 20, height: 20)
        iconCache[app.processIdentifier] = icon
        return icon
    }

    private func prewarmIcons() {
        for app in NSWorkspace.shared.runningApplications where isDiscoverable(app) {
            _ = icon(for: app)
        }
    }

    private func visibility(
        app: NSRunningApplication,
        window: AXWindow,
        windowMatch: CGWindowEntry?,
        settings: SwitcherSettings
    ) -> VisibilityResult {
        let result = WindowVisibilityResolver.visibility(
            for: WindowVisibilityInput(
                isAppActive: app.isActive,
                isMinimized: window.isMinimized,
                isMain: window.isMain,
                isFocused: window.isFocused,
                isFullScreen: isLikelyFullScreen(window),
                windowMatch: windowMatch
            ),
            settings: settings
        )
        return VisibilityResult(shouldInclude: result.shouldInclude, sortGroup: result.sortGroup)
    }

    private func compareRankedItems(_ lhs: RankedSwitcherItem, _ rhs: RankedSwitcherItem) -> Bool {
        lhs.rank.isOrderedBefore(rhs.rank)
    }

    private func isLikelyFullScreen(_ window: AXWindow) -> Bool {
        guard let frame = window.frame else {
            return false
        }
        return NSScreen.screens.contains { screen in
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                return false
            }
            return WindowOrdering.framesMatch(
                frame,
                CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            )
        }
    }

    private func windowActivationOrder(
        app: NSRunningApplication,
        window: AXWindow,
        context: SnapshotContext
    ) -> Int {
        context.windowActivationRecordsByPID[app.processIdentifier, default: []]
            .filter { $0.matches(window) }
            .map(\.order)
            .max() ?? 0
    }

    private struct SnapshotContext {
        let settings: SwitcherSettings
        let discoveredApps: [RegistryDiscoveredApp]
        let frontmostPID: pid_t?
        let frontmostBundleID: String?
        let windowActivationRecordsByPID: [pid_t: [WindowActivationRecord]]
        let windowOrdering: WindowOrdering
    }

    private struct DiscoveredWindow {
        let app: RegistryDiscoveredApp
        let window: AXWindow
        let windowIndex: Int
    }

    private struct WindowMatch {
        let entry: CGWindowEntry?

        var cgOrder: Int? {
            entry?.order
        }
    }

    private struct RankedSwitcherItem {
        let item: SwitcherItem
        let destination: DiscoveryItemDestination
        let sortGroup: WindowDiscoverySortGroup
        let cgOrder: Int?
        let activationOrder: Int
        let appOrder: Int
        let itemOrder: Int
        let windowPriority: Int
        let isFrontmostItem: Bool

        var rank: SwitcherItemRank {
            SwitcherItemRank(
                sortGroup: sortGroup.rawValue,
                cgOrder: cgOrder,
                activationOrder: activationOrder,
                appOrder: appOrder,
                itemOrder: itemOrder,
                windowPriority: windowPriority
            )
        }
    }

    private struct VisibilityResult {
        let shouldInclude: Bool
        let sortGroup: WindowDiscoverySortGroup
    }
}
