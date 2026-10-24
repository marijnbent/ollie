import AppKit
import Carbon.HIToolbox

enum AccessibilityReplacement: Equatable {
    case delivered
    case unavailable
    case rejected

    /// `.rejected` means the document is not the one we measured, so events would edit the wrong text.
    var fallsBackToEvents: Bool { self == .unavailable }
}

/// The two judgements a replacement makes, kept pure so the harness can drive both tiers.
enum TextReplacementPolicy {
    static func triggerRange(_ trigger: String, in value: String, selectedRange: NSRange) -> NSRange? {
        guard selectedRange.length == 0, selectedRange.location >= trigger.utf16.count,
              Range(selectedRange, in: value) != nil else { return nil }
        let replacementRange = NSRange(
            location: selectedRange.location - trigger.utf16.count, length: trigger.utf16.count)
        guard let range = Range(replacementRange, in: value),
              String(value[range]).caseInsensitiveCompare(trigger) == .orderedSame else { return nil }
        return replacementRange
    }

    /// Chromium answers `.success` and applies nothing, so the value has to read back as we wrote it.
    static func confirmsReplacement(
        originalValue: String,
        replacementRange: NSRange,
        insertedText: String,
        observedValue: String?
    ) -> Bool {
        guard let observedValue,
            let stringRange = Range(replacementRange, in: originalValue)
        else { return false }
        var expected = originalValue
        expected.replaceSubrange(stringRange, with: insertedText)
        return observedValue == expected
    }
}

@MainActor
final class DeliveryCompletion {
    private let onDelivered: @MainActor () -> Void
    private let onFailed: @MainActor () -> Void
    private(set) var isConfirmed = false
    private var isSettled = false

    init(
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.onDelivered = onDelivered
        self.onFailed = onFailed
    }

    func confirm() {
        guard !isSettled else { return }
        isSettled = true
        isConfirmed = true
        onDelivered()
    }

    /// Driven from a `defer`, so a delivery that returned early still says so instead of vanishing.
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        onFailed()
    }
}

@MainActor
final class TextInjector {

    private let deliveryQueue: DeliveryQueue
    private let pasteboard: any PasteboardAccess
    private let inlinePasteDelay: Duration
    private var activePasteboardLease: TemporaryPasteboardLease?

    init(
        deliveryQueue: DeliveryQueue = DeliveryQueue(),
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        inlinePasteDelay: Duration = .milliseconds(400)
    ) {
        self.deliveryQueue = deliveryQueue
        self.pasteboard = pasteboard
        self.inlinePasteDelay = inlinePasteDelay
    }

    /// A paste is still in flight, or we still hold the pasteboard it borrowed.
    var isDelivering: Bool { !deliveryQueue.isIdle || activePasteboardLease != nil }

    func prepareForTermination() {
        deliveryQueue.cancelAll()
        finishPendingPasteboardOwnership()
    }

    /// A hotkey's target comes from `frontmostApplication`, which can be Ollie itself.
    private func targetAcceptsInjection(_ targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp,
            !targetApp.isTerminated,
            targetApp.bundleIdentifier != Bundle.main.bundleIdentifier,
            !IsSecureEventInputEnabled()
        else { return false }
        return true
    }

    func captureExpansionContext(
        target: InjectionTarget?,
        clipboard: String
    ) -> QuicklinkTemplateEngine.ExpansionContext {
        QuicklinkTemplateEngine.ExpansionContext(
            clipboard: clipboard,
            selection: selection(in: target),
            now: Date(),
            calendar: Calendar.current,
            locale: Locale.current,
            timeZone: .current)
    }

    /// The caller must know there *is* a selection: a zero-length one inserts at the caret instead.
    func replaceSelection(
        with text: String,
        in targetApp: NSRunningApplication?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        deliver(
            text, target: targetApp.map(InjectionTarget.external),
            onDelivered: onDelivered, onFailed: onFailed)
    }

    /// A `changeCount` that never moves means nothing was selected, not that the old clipboard won.
    func copySelection(from targetApp: NSRunningApplication?) async -> String? {
        await deliveryQueue.drain()
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp),
            deliveryIsAllowed(
                targetApp: targetApp,
                promptForInteractiveAccessibility: true)
        else { return nil }
        return await copySelection(from: targetApp, pasteboard: NSPasteboard.general)
    }

    /// Split for the harness, which drives a stub pasteboard rather than another app.
    func copySelection(
        from targetApp: NSRunningApplication?, pasteboard: any PasteboardAccess
    ) async -> String? {
        guard let original = PasteboardSnapshot(pasteboard: pasteboard) else { return nil }
        defer { restore(original, to: pasteboard) }

        Paster.postCommandC(toPid: targetApp?.processIdentifier)
        for _ in 0..<Self.copyPollAttempts {
            guard await wait(for: Self.copyPollInterval) else { return nil }
            guard pasteboard.changeCount != original.changeCount else { continue }
            guard let copied = PasteboardSnapshot(pasteboard: pasteboard),
                let data = copied.firstStringData
            else { return nil }
            return String(bytes: data, encoding: .utf8)
        }
        return nil
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: any PasteboardAccess) {
        guard let items = snapshot.pasteboardItems() else { return }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return }
    }

    /// A copy lands well inside a second; past that the app was never going to answer.
    private static let copyPollAttempts = 40
    private static let copyPollInterval = Duration.milliseconds(25)

    private func deliver(
        _ text: String,
        target: InjectionTarget?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        let targetApp = target?.externalApp
        activate(targetApp)
        guard targetAcceptsInjection(targetApp), Permissions.ensureAccessibility() else {
            onFailed()
            return
        }
        deliveryQueue.enqueue { [weak self] in
            guard let self else { return }
            let completion = DeliveryCompletion(onDelivered: onDelivered, onFailed: onFailed)
            await self.performDelivery(
                text,
                targetApp: targetApp,
                completion: completion)
        }
    }

    private func performDelivery(
        _ text: String,
        targetApp: NSRunningApplication?,
        completion: DeliveryCompletion
    ) async {
        defer { completion.settle() }
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(
                targetApp),
            deliveryIsAllowed(
                targetApp: targetApp,
                promptForInteractiveAccessibility: true)
        else { return }

        let accessibilityReplacement = Self.replaceUsingAccessibility(
            text,
            targetApp: targetApp)
        if accessibilityReplacement == .delivered {
            completion.confirm()
            return
        }
        guard accessibilityReplacement.fallsBackToEvents else { return }

        guard
            await deliverUsingEvents(
                text,
                targetApp: targetApp)
        else { return }

        completion.confirm()
    }

    private func deliverUsingEvents(
        _ text: String,
        targetApp: NSRunningApplication?
    ) async -> Bool {
        let isShortSingleLine =
            text.count <= 100
            && !text.contains("\n")
            && !text.contains("\r")
        if isShortSingleLine {
            return await deliverUsingUnicodeEvents(
                text,
                targetApp: targetApp)
        }

        guard let lease = beginTemporaryPasteboardLease(text) else {
            return await deliverUsingUnicodeEvents(
                text,
                targetApp: targetApp)
        }
        activePasteboardLease = lease
        defer { finish(lease) }

        guard await wait(for: .milliseconds(80)),
            lease.isOwned,
            deliveryIsAllowed(
                targetApp: targetApp,
                promptForInteractiveAccessibility: false)
        else { return false }

        let stateBeforePaste = accessibilityTextState(in: targetApp)
        Paster.postCommandV(toPid: targetApp?.processIdentifier)
        return await waitForPasteConfirmation(
            previousState: stateBeforePaste,
            pasteboardLease: lease,
            targetApp: targetApp)
    }

    private func deliverUsingUnicodeEvents(
        _ text: String,
        targetApp: NSRunningApplication?
    ) async -> Bool {
        guard let insertionEvents = Self.makeUnicodeEvents(text),
            deliveryIsAllowed(
                targetApp: targetApp,
                promptForInteractiveAccessibility: false),
            await postEventGroups(insertionEvents, targetApp: targetApp)
        else { return false }

        return await wait(for: .milliseconds(100))
    }

    /// Each group is one keystroke, spaced so a target that stops accepting them halts the rest.
    private func postEventGroups(
        _ events: [[CGEvent]],
        targetApp: NSRunningApplication?
    ) async -> Bool {
        for index in events.indices {
            guard
                deliveryIsAllowed(
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }
            post(events[index], targetApp: targetApp)
            if index < events.count - 1,
                !(await wait(for: .milliseconds(8)))
            {
                return false
            }
        }
        return true
    }

    private func beginTemporaryPasteboardLease(_ text: String) -> TemporaryPasteboardLease? {
        return TemporaryPasteboardLease.begin(
            text: text, pasteboard: pasteboard)
    }

    @discardableResult
    private func finishPendingPasteboardOwnership() -> Bool {
        guard let lease = activePasteboardLease else { return true }
        for _ in 0..<3 where lease.isOwned { finish(lease) }
        return !lease.isOwned
    }

    private func finish(_ lease: TemporaryPasteboardLease) {
        switch lease.restoreIfOwned() {
        case .restored:
            break
        case .superseded:
            break
        case .failed:
            // Still ours, so leave `activePasteboardLease` in place for the retry below.
            if lease.isOwned { return }
        }
        if activePasteboardLease === lease { activePasteboardLease = nil }
    }

    private func deliveryIsAllowed(
        targetApp: NSRunningApplication?,
        promptForInteractiveAccessibility: Bool
    ) -> Bool {
        // Re-checked before every post, so a target that went away or went secure stops delivery.
        guard targetAcceptsInjection(targetApp), let targetApp,
            targetApp.isActive,
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetApp.processIdentifier
        else { return false }
        return promptForInteractiveAccessibility
            ? Permissions.ensureAccessibility()
            : Permissions.isAccessibilityTrusted()
    }

    private struct AccessibilityTextState: Equatable {
        let value: String
        let selectedRange: NSRange
    }

    private func activateAndWaitForTarget(
        _ targetApp: NSRunningApplication?
    ) async -> Bool {
        guard let targetApp else {
            return deliveryIsAllowed(
                targetApp: nil,
                promptForInteractiveAccessibility: false)
        }
        activate(targetApp)
        for _ in 0..<50 {
            if targetApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == targetApp.processIdentifier
            {
                return true
            }
            guard await wait(for: .milliseconds(20)) else { return false }
        }
        return false
    }

    private struct AccessibilityTarget {
        let element: AXUIElement
        let value: String
        let originalRange: NSRange
        let replacementRange: NSRange
    }

    private enum AccessibilityTargetState {
        case ready(AccessibilityTarget)
        case unavailable
        case rejected
    }

    /// Rule 1: a renderer surface answers about its own model, so it is never written to over AX.
    private static func replaceUsingAccessibility(
        _ text: String,
        targetApp: NSRunningApplication?
    ) -> AccessibilityReplacement {
        guard let targetApp else { return .unavailable }
        let state = Self.inspectAccessibilityTarget(in: targetApp)
        guard case .ready(let target) = state else {
            if case .rejected = state { return .rejected }
            return .unavailable
        }

        guard Self.setSelectedRange(target.replacementRange, in: target.element) else {
            return .unavailable
        }
        guard
            AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                text as CFString) == .success
        else {
            _ = Self.setSelectedRange(target.originalRange, in: target.element)
            return .unavailable
        }

        let observed = Self.stringValue(in: target.element)
        guard
            TextReplacementPolicy.confirmsReplacement(
                originalValue: target.value,
                replacementRange: target.replacementRange,
                insertedText: text,
                observedValue: observed)
        else {
            _ = Self.setSelectedRange(target.originalRange, in: target.element)
            // An untouched value is a tier that did nothing; anything else moved text we cannot name.
            return observed == target.value ? .unavailable : .rejected
        }

        _ = Self.setSelectedRange(
            NSRange(
                location: target.replacementRange.location + text.utf16.count, length: 0),
            in: target.element)
        return .delivered
    }

    private static func inspectAccessibilityTarget(
        in targetApp: NSRunningApplication,
        replacingSuffix: String? = nil
    ) -> AccessibilityTargetState {
        guard let element = AccessibilityText.focusedElement(in: targetApp),
            !Self.usesTextMarkerSelection(element),
            Self.isAttributeSettable(kAXSelectedTextRangeAttribute, in: element),
            Self.isAttributeSettable(kAXSelectedTextAttribute, in: element),
            let value = Self.stringValue(in: element),
            let originalRange = Self.selectedRange(in: element)
        else { return .unavailable }

        guard Range(originalRange, in: value) != nil else { return .unavailable }
        var replacementRange = originalRange
        if let replacingSuffix {
            guard let range = TextReplacementPolicy.triggerRange(
                replacingSuffix, in: value, selectedRange: originalRange) else { return .rejected }
            replacementRange = range
        }
        return .ready(
            AccessibilityTarget(
                element: element, value: value, originalRange: originalRange,
                replacementRange: replacementRange))
    }

    /// Web content and Monaco expose selection only as markers; their `AXValue` trails or is empty.
    private static func usesTextMarkerSelection(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &value) == .success,
            let value
        else { return false }
        return CFGetTypeID(value) == AXTextMarkerRangeGetTypeID()
    }

    private func waitForPasteConfirmation(
        previousState: AccessibilityTextState?,
        pasteboardLease: TemporaryPasteboardLease,
        targetApp: NSRunningApplication?
    ) async -> Bool {
        var readStateAfterPaste = false
        for attempt in 0..<80 {
            guard pasteboardLease.isOwned,
                deliveryIsAllowed(
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }

            if let previousState,
                let currentState = accessibilityTextState(in: targetApp)
            {
                readStateAfterPaste = true
                if currentState != previousState { return true }
            }
            if PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: attempt,
                hadPreviousState: previousState != nil,
                readStateAfterPaste: readStateAfterPaste)
            {
                return true
            }
            guard await wait(for: .milliseconds(25)) else { return false }
        }
        return false
    }

    private func accessibilityTextState(
        in targetApp: NSRunningApplication?
    ) -> AccessibilityTextState? {
        guard let targetApp,
            let element = AccessibilityText.focusedElement(in: targetApp),
            !Self.usesTextMarkerSelection(element),
            let value = Self.stringValue(in: element),
            let selectedRange = Self.selectedRange(in: element)
        else { return nil }
        return AccessibilityTextState(value: value, selectedRange: selectedRange)
    }

    private static func stringValue(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &value) == .success
        else { return nil }
        return value as? String
    }

    private static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setSelectedRange(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value) == .success
    }

    private static func isAttributeSettable(_ attribute: String, in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element,
                attribute as CFString,
                &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private func activate(_ targetApp: NSRunningApplication?) {
        guard targetApp?.isTerminated == false else { return }
        targetApp?.activate()
    }

    private func selection(in target: InjectionTarget?) -> String {
        switch target {
        case .ownEditor(let editor): return editor.injectableSelection
        case .external(let app): return selectedText(in: app) ?? ""
        case nil: return ""
        }
    }

    private func selectedText(in targetApp: NSRunningApplication?) -> String? {
        guard Permissions.isAccessibilityTrusted(), let targetApp else { return nil }
        return AccessibilityText.selection(in: targetApp)
    }

    static func inlineTriggerIsValid(_ trigger: String, in targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp else { return true }
        if case .rejected = inspectAccessibilityTarget(in: targetApp, replacingSuffix: trigger) { return false }
        return true
    }

    /// Read ahead of the completing key, which would otherwise wait on a slow clipboard owner.
    func prepareInlinePaste() -> PasteboardSnapshot? {
        guard !isDelivering else { return nil }
        return PasteboardSnapshot(pasteboard: pasteboard)
    }

    func pasteInline(
        _ text: String,
        deleting characterCount: Int,
        prepared: PasteboardSnapshot? = nil,
        postEvent: (CGEvent) -> Void,
        onFinished: @escaping @MainActor () -> Void
    ) -> Bool {
        guard deliveryQueue.isIdle, finishPendingPasteboardOwnership(),
              let events = Self.inlinePasteEvents(deleting: characterCount),
              let lease = TemporaryPasteboardLease.begin(text: text, pasteboard: pasteboard, prepared: prepared)
        else { return false }
        activePasteboardLease = lease
        deliveryQueue.enqueue { [weak self] in
            guard let self else {
                _ = lease.restoreIfOwned()
                onFinished()
                return
            }
            _ = await wait(for: inlinePasteDelay)
            finish(lease)
            onFinished()
        }
        for event in events { postEvent(event) }
        return true
    }

    static func inlinePasteEvents(deleting characterCount: Int) -> [CGEvent]? {
        guard let deletions = inlineReplacementEvents(deleting: characterCount, inserting: ""),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
            tag(event)
        }
        return deletions + [down, up]
    }

    static func inlineReplacementEvents(deleting characterCount: Int, inserting text: String) -> [CGEvent]? {
        guard let insertion = makeUnicodeEvents(text) else { return nil }
        var events: [CGEvent] = []
        for _ in 0..<characterCount {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { return nil }
            for event in [down, up] {
                event.flags = []
                tag(event)
                events.append(event)
            }
        }
        return events + insertion.flatMap { $0 }
    }

    private static func makeUnicodeEvents(_ text: String) -> [[CGEvent]]? {
        guard !text.isEmpty else { return [] }
        var groups: [[CGEvent]] = []
        for chunk in UnicodeTypingChunk.split(text) {
            guard let pair = Self.makeUnicodeEvent(chunk) else { return nil }
            groups.append(pair)
        }
        return groups
    }

    private static func makeUnicodeEvent(_ chunk: [UniChar]) -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        var characters = chunk
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false)
        else { return nil }
        // The source inherits held modifiers, and a hotkey's are still down while this types.
        down.flags = []
        up.flags = []
        Self.tag(down)
        Self.tag(up)
        down.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters)
        up.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters)
        return [down, up]
    }

    private static func tag(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Paster.ollieEventTag)
    }

    private func post(_ events: [CGEvent], targetApp: NSRunningApplication?) {
        for event in events { post(event, targetApp: targetApp) }
    }

    private func post(_ event: CGEvent, targetApp: NSRunningApplication?) {
        if let pid = targetApp?.processIdentifier {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// Blink keeps one key event's text in a fixed four-unit array, so Chromium drops everything past it.
enum UnicodeTypingChunk {
    static let maxUTF16Units = 4

    /// Split on scalar boundaries: a lone surrogate half is not text, and a scalar always fits four.
    static func split(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxUTF16Units)
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                if !current.isEmpty { chunks.append(current) }
                current = []
                var control: [UniChar] = []
                UTF16.encode(scalar) { control.append($0) }
                chunks.append(control)
                continue
            }
            if current.count + UTF16.width(scalar) > maxUTF16Units {
                chunks.append(current)
                current = []
            }
            UTF16.encode(scalar) { current.append($0) }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

enum PasteConfirmationPolicy {
    static func acceptsUnconfirmedDelivery(
        attempt: Int,
        hadPreviousState: Bool,
        readStateAfterPaste: Bool
    ) -> Bool {
        attempt >= 15 && (!hadPreviousState || !readStateAfterPaste)
    }
}

@MainActor
final class DeliveryQueue {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: (id: UUID, task: Task<Void, Never>)?

    var isIdle: Bool { tasks.isEmpty }

    func enqueue(
        operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        let predecessor = tail?.task
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finish(id: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        tail = (id, task)
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tail = nil
    }

    func drain() async {
        await tail?.task.value
    }

    private func finish(id: UUID) {
        tasks.removeValue(forKey: id)
        if tail?.id == id { tail = nil }
    }
}

@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

@MainActor
final class TemporaryPasteboardLease {
    enum RestoreResult: Equatable {
        case restored(changeCount: Int)
        case superseded
        case failed
    }

    private let pasteboard: any PasteboardAccess
    private let ownedChangeCount: Int
    private let original: PasteboardSnapshot
    private var isFinished = false

    var isOwned: Bool {
        !isFinished && pasteboard.changeCount == ownedChangeCount
    }

    private init(
        pasteboard: any PasteboardAccess,
        ownedChangeCount: Int,
        original: PasteboardSnapshot
    ) {
        self.pasteboard = pasteboard
        self.ownedChangeCount = ownedChangeCount
        self.original = original
    }

    /// A `prepared` snapshot counts only while `changeCount` proves the clipboard is still that copy.
    static func begin(
        text: String,
        pasteboard: any PasteboardAccess,
        prepared: PasteboardSnapshot? = nil,
        onMutation: (Int) -> Void = { _ in }
    ) -> TemporaryPasteboardLease? {
        let current = prepared.flatMap { $0.changeCount == pasteboard.changeCount ? $0 : nil }
        guard let snapshot = current ?? PasteboardSnapshot(pasteboard: pasteboard),
            let temporaryItem = PasteboardSnapshot.temporaryItem(carrying: text),
            let originalItems = snapshot.pasteboardItems(),
            pasteboard.changeCount == snapshot.changeCount
        else { return nil }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([temporaryItem]) else {
            if originalItems.isEmpty || pasteboard.writeObjects(originalItems) {
                onMutation(pasteboard.changeCount)
            }
            return nil
        }
        let ownedChangeCount = pasteboard.changeCount
        onMutation(ownedChangeCount)
        return TemporaryPasteboardLease(
            pasteboard: pasteboard,
            ownedChangeCount: ownedChangeCount,
            original: snapshot)
    }

    /// The lent board holds nothing of the original, so restoring rewrites the snapshot whole.
    func restoreIfOwned() -> RestoreResult {
        guard !isFinished else { return .superseded }
        guard pasteboard.changeCount == ownedChangeCount else {
            isFinished = true
            return .superseded
        }
        guard let items = original.pasteboardItems() else { return .failed }
        pasteboard.clearContents()
        isFinished = true
        guard items.isEmpty || pasteboard.writeObjects(items) else { return .failed }
        return .restored(changeCount: pasteboard.changeCount)
    }
}

@MainActor
struct PasteboardSnapshot {
    struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]
    let changeCount: Int

    var firstStringData: Data? {
        items.first?.values.first { $0.type == .string }?.data
    }

    init?(pasteboard: any PasteboardAccess) {
        let changeCount = pasteboard.changeCount
        var items: [Item] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in pasteboardItem.types {
                guard let data = pasteboardItem.data(forType: type) else { return nil }
                values.append((type: type, data: data))
            }
            items.append(Item(values: values))
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        self.items = items
        self.changeCount = changeCount
    }

    /// A kept `public.html` is the flavour a Chromium editor prefers, so we lend the text alone.
    static func temporaryItem(carrying text: String) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        else { return nil }
        return item
    }

    func pasteboardItems() -> [NSPasteboardItem]? {
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(items.count)
        for item in items {
            let pasteboardItem = NSPasteboardItem()
            for value in item.values {
                guard pasteboardItem.setData(value.data, forType: value.type) else { return nil }
            }
            pasteboardItems.append(pasteboardItem)
        }
        return pasteboardItems
    }
}
