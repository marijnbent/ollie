import AppKit
import Carbon.HIToolbox

enum Paster {
    static let ollieEventTag: Int64 = 0x54494E59

    struct ActivationTiming: Sendable {
        var poll = Duration.milliseconds(10)
        var reactivateAfter = Duration.milliseconds(300)
        var timeout = Duration.milliseconds(1500)
        /// Frontmost is not yet key: the target's key window needs a beat before it takes ⌘V.
        var settle = Duration.milliseconds(40)
    }

    /// No activation to wait on, only Ollie's own window taking key again.
    private static let ownWindowDelay = Duration.milliseconds(80)

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay = Duration.milliseconds(50)

    private static let diagnostics = Diagnostics(category: "paste")

    @MainActor
    static func copyPlainText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        copyPlainText(text)
        let changeCount = NSPasteboard.general.changeCount
        Task { await paste(into: previousApp, expectedChangeCount: changeCount) }
    }

    /// A file, pasted into `previousApp`; the receiver takes the file or its path, as it reads.
    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        PasteboardFiles.write(url, to: .general)
        let changeCount = NSPasteboard.general.changeCount
        Task { await paste(into: previousApp, expectedChangeCount: changeCount) }
    }

    /// Paste into `app` without activating or promoting, so the palette and its rows hold still.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        copyPlainText(text)
        guard let pid = app?.processIdentifier else { return }
        Task {
            guard (try? await Task.sleep(for: directPostDelay)) != nil else { return }
            postCommandV(toPid: pid)
        }
    }

    /// Brings `target` forward and pastes once it is frontmost; `nil` or Ollie pastes into Ollie.
    @MainActor
    @discardableResult
    static func paste(into target: NSRunningApplication?, expectedChangeCount: Int? = nil) async -> Bool {
        guard Permissions.ensureAccessibility() else { return false }
        guard let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            guard await pause(ownWindowDelay) else { return false }
            return postCommandV()
        }
        guard !target.isTerminated else { return false }
        return await paste(
            on: .general, expectedChangeCount: expectedChangeCount,
            targetName: target.bundleIdentifier ?? "pid \(target.processIdentifier)",
            activate: { target.activate() },
            isTargetActive: { isFrontmost(target) },
            sendPaste: { postCommandV() })
    }

    /// Split from `paste(into:)` so the harness drives it without touching the desktop.
    @MainActor
    static func paste(
        on pasteboard: NSPasteboard, expectedChangeCount: Int?, targetName: String,
        activate: () -> Void, isTargetActive: () -> Bool, sendPaste: () -> Bool,
        timing: ActivationTiming = ActivationTiming()
    ) async -> Bool {
        guard let waited = await activateAndWait(activate: activate, isActive: isTargetActive, timing: timing)
        else {
            if !Task.isCancelled { diagnostics.warning("paste.target_not_frontmost", details: targetName) }
            return false
        }
        guard await pause(timing.settle), isTargetActive() else {
            if !Task.isCancelled { diagnostics.warning("paste.target_lost_focus", details: targetName) }
            return false
        }
        if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount {
            diagnostics.warning("paste.clipboard_changed", details: targetName)
            return false
        }
        diagnostics.info("paste into \(targetName) after \(Diagnostics.format(Diagnostics.milliseconds(from: waited))) ms")
        return sendPaste()
    }

    @MainActor
    static func activateAndWait(for target: NSRunningApplication) async -> Bool {
        guard !target.isTerminated else { return false }
        return await activateAndWait(
            activate: { target.activate() }, isActive: { isFrontmost(target) }, timing: ActivationTiming()) != nil
    }

    /// The time it took, or `nil` when the target never came forward or the wait was cancelled.
    @MainActor
    static func activateAndWait(
        activate: () -> Void, isActive: () -> Bool, timing: ActivationTiming
    ) async -> Duration? {
        let start = ContinuousClock.now
        var reactivated = false
        activate()
        while !isActive() {
            let elapsed = start.duration(to: .now)
            guard elapsed < timing.timeout else { return nil }
            if !reactivated, elapsed >= timing.reactivateAfter {
                reactivated = true
                activate()
            }
            guard await pause(timing.poll) else { return nil }
        }
        return Task.isCancelled ? nil : start.duration(to: .now)
    }

    @MainActor
    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func pause(_ duration: Duration) async -> Bool {
        (try? await Task.sleep(for: duration)) != nil
    }

    /// Synthesize ⌘V, to `pid` alone when given, else through the system tap.
    @discardableResult
    static func postCommandV(toPid pid: pid_t? = nil) -> Bool {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @discardableResult
    static func postCommandC(toPid pid: pid_t? = nil) -> Bool {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) -> Bool {
        guard Permissions.ensureAccessibility() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: ollieEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: ollieEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }
}
