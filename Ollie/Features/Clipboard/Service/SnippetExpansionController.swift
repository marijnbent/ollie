import Cocoa
import SwiftUI
import ApplicationServices

@MainActor
final class SnippetExpansionController {
    private let generatedEventMarker: Int64 = Paster.ollieEventTag
    private let metrics: () -> InterfaceMetrics
    private let store: SnippetStore
    private let injector: TextInjector
    private let frontmostApplication: () -> NSRunningApplication?
    private let replayEvent: (CGEvent) -> Void
    private enum InlineReplacement {
        case pasted
        case rejected
    }
    private var pendingPasteID: UUID?
    private var bufferedEvents: [CGEvent] = []
    private lazy var suggestionWindowController = SnippetSuggestionWindowController(
        metrics: metrics,
        onActivateSuggestion: { [weak self] index in
            guard let self, suggestions.indices.contains(index) else { return }
            activate(suggestions[index])
        },
        onHoverSuggestion: { [weak self] index in
            self?.selectSuggestion(at: index)
        }
    )

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeQuery: String?
    private var draftContent: String?
    private var previousCharacter: Character?
    private var suggestions: [SnippetSuggestion] = []
    private var selectedIndex = 0
    private var hasNavigatedSuggestions = false
    private var openingTask: Task<Void, Never>?
    private var openingCaretRect: CGRect?
    private var activationObserver: NotificationToken?
    private var sessionAnchorRect: CGRect?
    private var sessionAnchorStrategy: AnchorStrategy?
    private var axObserver: AXObserver?
    private var axObserverSource: CFRunLoopSource?
    private var observedApplication: NSRunningApplication?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedWindow: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var lastAnchorLogKey: String?
    private var lastObserverLogKey: String?
    private var lastActivationLogKey: String?

    init(
        store: SnippetStore,
        injector: TextInjector,
        metrics: @escaping () -> InterfaceMetrics = { .standard },
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        replayEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) {
        self.store = store
        self.injector = injector
        self.metrics = metrics
        self.frontmostApplication = frontmostApplication
        self.replayEvent = replayEvent
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start() {
        guard eventTap == nil else { return }

        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<SnippetExpansionController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handle(type: type, event: event) { $0.tapPostEvent(proxy) }
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Diagnostics(category: "snippets").error("Failed to create snippet event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        let center = NSWorkspace.shared.notificationCenter
        activationObserver = NotificationToken(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelSession()
                self?.cancelPendingInput()
                self?.previousCharacter = nil
            }
        }, center: center)
    }

    func stop() {
        cancelSession()
        cancelPendingInput()

        activationObserver = nil
        previousCharacter = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    func handle(type: CGEventType, event: CGEvent, postEvent: (CGEvent) -> Void) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == generatedEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if pendingPasteID != nil {
            if type == .keyDown || type == .keyUp {
                guard let copy = event.copy() else { return Unmanaged.passUnretained(event) }
                bufferedEvents.append(copy)
                return nil
            }
            for buffered in bufferedEvents { postEvent(buffered) }
            cancelPendingInput()
        }

        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        defer {
            let modifiers = nsEvent.modifierFlags.intersection([.command, .control, .option])
            previousCharacter = modifiers.isEmpty ? nsEvent.characters?.last : nil
            if [51, 123, 124, 125, 126].contains(nsEvent.keyCode) { previousCharacter = nil }
        }

        if shouldConsumeControlKey(nsEvent, postEvent: postEvent) {
            return nil
        }

        if processTextKey(nsEvent, postEvent: postEvent) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func shouldConsumeControlKey(_ event: NSEvent, postEvent: (CGEvent) -> Void) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            guard isSessionActive else { return false }
            cancelSession()
            return true
        case 125: // Down
            guard hasSuggestions else { return false }
            hasNavigatedSuggestions = true
            selectedIndex = min(selectedIndex + 1, suggestions.count - 1)
            refreshSuggestions()
            return true
        case 126: // Up
            guard hasSuggestions else { return false }
            hasNavigatedSuggestions = true
            selectedIndex = max(selectedIndex - 1, 0)
            refreshSuggestions()
            return true
        case 36 where draftContent != nil, 48 where draftContent != nil: // Return, Tab
            return commitDraft(postEvent: postEvent)
        case 36: // Return
            guard hasSuggestions,
                  let suggestion = selectedSuggestion,
                  shouldCommitSnippetSelectionOnReturn else { return false }
            return activate(suggestion, postEvent: postEvent)
        case 48: // Tab
            guard hasSuggestions, let suggestion = selectedSuggestion else { return false }
            return activate(suggestion, postEvent: postEvent)
        case 51: // Backspace
            guard let activeQuery else { return false }
            if let draftContent {
                self.draftContent = draftContent.isEmpty ? nil : String(draftContent.dropLast())
                refreshSuggestionsAsync()
            } else if activeQuery.isEmpty {
                cancelSession()
            } else {
                self.activeQuery = String(activeQuery.dropLast())
                selectedIndex = 0
                refreshSuggestionsAsync()
            }
            return false
        default:
            return false
        }
    }

    private func processTextKey(_ event: NSEvent, postEvent: (CGEvent) -> Void) -> Bool {
        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.characters ?? ""

        guard !isTypingInsideClippie else {
            if isSessionActive {
                cancelSession()
            }
            return false
        }

        if draftContent != nil {
            if disallowedModifiers.isEmpty, SnippetExpansionPolicy.isDraftText(characters) {
                draftContent? += characters
                refreshSuggestionsAsync()
            } else if event.keyCode != 51 {
                cancelSession()
            }
            return false
        }

        if characters == ">" && disallowedModifiers.isEmpty {
            let element = focusedElement()
            let value = element.flatMap { stringAttribute(kAXValueAttribute as CFString, for: $0) }
            let range = element.flatMap { selectedTextRange(for: $0) }.map {
                NSRange(location: $0.location, length: $0.length)
            }
            cancelSession()
            if SnippetExpansionPolicy.canStartSession(
                value: value, selectedRange: range, previousCharacter: previousCharacter
            ) {
                startSession()
            }
            return false
        }

        guard let activeQuery else { return false }

        if !disallowedModifiers.isEmpty {
            cancelSession()
            return false
        }

        if event.keyCode == 51 { return false }

        if characters == " ", !activeQuery.isEmpty, exactMatch(for: activeQuery) == nil {
            beginDraft()
            return false
        }

        guard Snippet.isSupportedTriggerCharacter(characters) else {
            cancelSession()
            return false
        }

        let normalizedCharacters = Snippet.normalizeTrigger(characters)
        if normalizedCharacters.count == 1, let scalar = normalizedCharacters.first {
            self.activeQuery = activeQuery + String(scalar)
            selectedIndex = 0
            if let query = self.activeQuery,
               let exactMatch = exactMatch(for: query),
               SnippetExpansionPolicy.shouldAutoExpand(exactMatch, among: store.matches(for: query)) {
                return expand(exactMatch, pendingCharacterCount: 1, postEvent: postEvent)
            }
            refreshSuggestionsAsync()
            return false
        }

        cancelSession()
        return false
    }

    private func refreshSuggestionsAsync() {
        Task { @MainActor [weak self] in
            self?.refreshSuggestions()
        }
    }

    private func refreshSuggestions() {
        guard let activeQuery else {
            suggestionWindowController.hide()
            return
        }

        ensureObservationTargetCurrent()

        suggestions = makeSuggestions(for: activeQuery)
        if selectedIndex >= suggestions.count {
            selectedIndex = max(0, suggestions.count - 1)
        }

        guard !suggestions.isEmpty else {
            suggestionWindowController.hide()
            return
        }

        let anchorResolution = resolveSessionAnchor()
        if openingTask != nil {
            guard anchorResolution.strategy.isCaret, anchorResolution.rect != openingCaretRect else { return }
            openingTask?.cancel()
            openingTask = nil
            openingCaretRect = nil
        }
        if anchorResolution.strategy != .screenCenter && anchorResolution.strategy != .pointer
            && anchorResolution.strategy != .cachedPosition {
            sessionAnchorRect = anchorResolution.rect
            sessionAnchorStrategy = anchorResolution.strategy
        }
        logAnchorResolutionIfNeeded(anchorResolution)

        suggestionWindowController.show(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            anchorRect: anchorResolution.rect,
            anchorStrategy: anchorResolution.strategy
        )
    }

    private func cancelSession() {
        openingTask?.cancel()
        openingTask = nil
        openingCaretRect = nil
        activeQuery = nil
        draftContent = nil
        suggestions = []
        selectedIndex = 0
        hasNavigatedSuggestions = false
        sessionAnchorRect = nil
        sessionAnchorStrategy = nil
        lastAnchorLogKey = nil
        suggestionWindowController.hide()
        stopObservingActiveTarget()
    }

    private var isSessionActive: Bool {
        activeQuery != nil
    }

    private var hasSuggestions: Bool {
        !suggestions.isEmpty && (openingTask != nil || suggestionWindowController.isVisible)
    }

    private var selectedSuggestion: SnippetSuggestion? {
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        return suggestions[selectedIndex]
    }

    private func makeSuggestions(for query: String) -> [SnippetSuggestion] {
        if let draftContent { return [.draft(SnippetDraft(trigger: query, content: draftContent))] }
        let snippets = store.matches(for: query).map(SnippetSuggestion.snippet)
        guard !query.isEmpty, exactMatch(for: query) == nil else { return snippets }
        let create = SnippetSuggestion.draft(SnippetDraft(trigger: query, content: nil))
        return snippets + [create]
    }

    private func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        suggestionWindowController.update(suggestions: suggestions, selectedIndex: selectedIndex)
    }

    @discardableResult
    private func activate(
        _ suggestion: SnippetSuggestion,
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cgAnnotatedSessionEventTap) }
    ) -> Bool {
        switch suggestion {
        case .snippet(let snippet):
            return expand(snippet, postEvent: postEvent)
        case .draft(let draft) where draft.content == nil:
            guard let space = TextInjector.inlineReplacementEvents(deleting: 0, inserting: " ") else { return false }
            beginDraft()
            for event in space { postEvent(event) }
            return true
        case .draft:
            return commitDraft(postEvent: postEvent)
        }
    }

    private func beginDraft() {
        draftContent = ""
        selectedIndex = 0
        suggestions = makeSuggestions(for: activeQuery ?? "")
        refreshSuggestionsAsync()
    }

    private func startSession() {
        activeQuery = ""
        suggestions = makeSuggestions(for: "")
        selectedIndex = 0
        hasNavigatedSuggestions = false
        sessionAnchorRect = nil
        sessionAnchorStrategy = nil
        lastAnchorLogKey = nil
        ensureObservationTargetCurrent()
        let anchor = resolveSessionAnchor()
        openingCaretRect = anchor.strategy.isCaret ? anchor.rect : nil
        openingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(32))
            } catch {
                return
            }
            guard let self else { return }
            openingTask = nil
            openingCaretRect = nil
            refreshSuggestions()
        }
        refreshSuggestionsAsync()
    }

    @discardableResult
    private func expand(
        _ snippet: Snippet,
        pendingCharacterCount: Int = 0,
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cgAnnotatedSessionEventTap) }
    ) -> Bool {
        let trigger = ">" + (activeQuery ?? "")
        let forwardedTrigger = String(trigger.dropLast(pendingCharacterCount))
        guard let replacement = replaceTypedText(forwardedTrigger, with: snippet.content, postEvent: postEvent) else {
            return false
        }
        if replacement == .pasted { store.recordUsage(for: snippet.id) }
        return true
    }

    @discardableResult
    private func commitDraft(
        postEvent: (CGEvent) -> Void = { $0.post(tap: .cgAnnotatedSessionEventTap) }
    ) -> Bool {
        guard let trigger = activeQuery, let draftContent else { return false }
        let accessibilityDraft = focusedElement().flatMap { element -> (typed: String, content: String)? in
            guard let value = stringAttribute(kAXValueAttribute as CFString, for: element),
                  let range = selectedTextRange(for: element) else { return nil }
            return SnippetExpansionPolicy.draft(
                in: value, selectedRange: NSRange(location: range.location, length: range.length), trigger: trigger)
        }
        let draft = accessibilityDraft ?? (">\(trigger) \(draftContent)", draftContent)
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            cancelSession()
            return false
        }
        do {
            try store.saveSnippet(title: "", trigger: trigger, content: content)
        } catch {
            Diagnostics(category: "snippets").warning("Inline snippet not saved", details: error.localizedDescription)
            cancelSession()
            return false
        }
        _ = replaceTypedText(draft.typed, with: content, postEvent: postEvent)
        return true
    }

    @discardableResult
    private func replaceTypedText(
        _ typed: String, with content: String, postEvent: (CGEvent) -> Void
    ) -> InlineReplacement? {
        let target = frontmostApplication()
        cancelSession()
        guard TextInjector.inlineTriggerIsValid(typed, in: target) else {
            Diagnostics(category: "snippets").warning("Snippet replacement target changed")
            return .rejected
        }
        let pasteID = UUID()
        pendingPasteID = pasteID
        guard injector.pasteInline(content, deleting: typed.count, postEvent: postEvent, onFinished: { [weak self] in
            guard let self, pendingPasteID == pasteID else { return }
            let events = bufferedEvents
            cancelPendingInput()
            guard frontmostApplication()?.processIdentifier == target?.processIdentifier else { return }
            for event in events { replayEvent(event) }
        }) else {
            cancelPendingInput()
            return nil
        }
        playInsertionSound()
        return .pasted
    }

    private func cancelPendingInput() {
        pendingPasteID = nil
        bufferedEvents.removeAll()
    }

    private func caretRect(for focusedElement: AXUIElement) -> CGRect? {
        guard let selectedRange = selectedTextRange(for: focusedElement),
              let bounds = boundsForRange(selectedRange, in: focusedElement) else {
            return nil
        }

        let elementFrame = accessibilityFrame(for: focusedElement)
        return resolvedCaretRect(fromAccessibilityBounds: bounds, constrainedTo: elementFrame)
    }

    private func focusedElementRect(for focusedElement: AXUIElement) -> CGRect? {
        let role = stringAttribute(kAXRoleAttribute as CFString, for: focusedElement)
        guard role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole,
              let bounds = accessibilityFrame(for: focusedElement) else { return nil }

        return resolvedElementRect(fromAccessibilityBounds: bounds)
    }

    private func focusedWindowRect() -> CGRect? {
        guard let focusedWindow = currentFocusedWindow(),
              let bounds = accessibilityFrame(for: focusedWindow) else {
            return nil
        }

        return resolvedElementRect(fromAccessibilityBounds: bounds)
    }

    private func fallbackAnchorRect() -> CGRect {
        let screen = preferredFallbackScreen()
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 1, height: 1)
    }

    private func preferredFallbackScreen() -> NSScreen? {
        if let sessionAnchorRect,
           let screen = screen(containing: sessionAnchorRect) {
            return screen
        }

        if let focusedWindowRect = focusedWindowRect(),
           let screen = screen(containing: focusedWindowRect) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let anchorPoint = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: {
            $0.frame.contains(anchorPoint) || $0.visibleFrame.intersects(rect)
        })
    }

    private func resolveSessionAnchor() -> AnchorResolution {
        let frontmostApplication = frontmostApplication()
        let bundleIdentifier = frontmostApplication?.bundleIdentifier
        let processID = frontmostApplication?.processIdentifier
        let focusedElement = currentFocusedElement()
        let focusedRole = focusedElement.flatMap { stringAttribute(kAXRoleAttribute as CFString, for: $0) }
        let focusedSubrole = focusedElement.flatMap { stringAttribute(kAXSubroleAttribute as CFString, for: $0) }

        var rect: CGRect?
        var strategy = AnchorStrategy.screenCenter
        if let focusedElement {
            if let caret = caretRect(for: focusedElement) {
                rect = caret
                strategy = .caretBounds
            } else if let caret = textMarkerCaretRect(for: focusedElement) {
                rect = caret
                strategy = .textMarkerCaret
            }
        }
        if rect == nil, let focusedElement, let elementRect = focusedElementRect(for: focusedElement) {
            rect = CGRect(x: elementRect.minX, y: elementRect.minY, width: 1, height: 1)
            strategy = .textElement
        }
        if rect == nil, let windowRect = focusedWindowRect() {
            rect = focusedWindowAnchorRect(from: windowRect)
            strategy = .focusedWindow
        }
        if rect == nil, let sessionAnchorRect {
            rect = sessionAnchorRect
            strategy = .cachedPosition
        }
        if rect == nil, NSScreen.screens.contains(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            rect = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
            strategy = .pointer
        }
        return AnchorResolution(
            rect: rect ?? fallbackAnchorRect(),
            strategy: strategy,
            bundleIdentifier: bundleIdentifier,
            processID: processID,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole
        )
    }

    private func textMarkerCaretRect(for element: AXUIElement) -> CGRect? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextMarkerRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = unsafeDowncast(selection, to: AXTextMarkerRange.self)
        let end = AXTextMarkerRangeCopyEndMarker(range)
        let caret = AXTextMarkerRangeCreate(kCFAllocatorDefault, end, end)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, caret, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &bounds) else { return nil }
        return resolvedCaretRect(fromAccessibilityBounds: bounds, constrainedTo: accessibilityFrame(for: element))
    }

    private func exactMatch(for query: String) -> Snippet? {
        store.exactTriggerMatch(for: query)
    }

    private var isTypingInsideClippie: Bool {
        guard let frontmostApplication = frontmostApplication() else {
            return false
        }

        return frontmostApplication.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func focusedElement() -> AXUIElement? {
        guard frontmostApplication() != nil else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(focusedElementRef, to: AXUIElement.self)
    }

    private func currentFocusedElement() -> AXUIElement? {
        observedFocusedElement ?? focusedElement()
    }

    private func currentFocusedWindow() -> AXUIElement? {
        if let observedFocusedWindow {
            return observedFocusedWindow
        }

        guard let observedApplicationElement else {
            return nil
        }

        return focusedWindow(in: observedApplicationElement)
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = selectedRangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    private func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var insertionRange = range
        insertionRange.length = 0
        guard let insertionRangeValue = AXValueCreate(.cfRange, &insertionRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            insertionRangeValue,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = boundsRef as! AXValue
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &bounds) else {
            return nil
        }

        return bounds
    }

    private func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func focusedWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        axElementAttribute(kAXFocusedWindowAttribute as CFString, for: applicationElement)
            ?? axElementAttribute(kAXMainWindowAttribute as CFString, for: applicationElement)
    }

    private func focusedWindowAnchorRect(from windowRect: CGRect) -> CGRect? {
        guard windowRect.width > 0, windowRect.height > 0 else {
            return nil
        }

        let anchorX = min(windowRect.maxX - 24, windowRect.minX + 28)
        let anchorY = max(windowRect.minY + 24, windowRect.maxY - 56)
        return CGRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func resolvedCaretRect(fromAccessibilityBounds bounds: CGRect, constrainedTo accessibilityElementBounds: CGRect?) -> CGRect? {
        guard isFinite(bounds), bounds.width >= 0, bounds.height > 0, bounds.height <= 200 else {
            return nil
        }

        guard var convertedBounds = appKitRect(fromAccessibilityRect: bounds) else {
            return nil
        }

        if bounds.origin == .zero && bounds.size == .zero {
            return nil
        }

        if convertedBounds.width <= 0 {
            convertedBounds.size.width = 1
        }

        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { partialResult, screen in
            partialResult = partialResult.union(screen.frame)
        }
        let sanityFrame = desktopFrame.insetBy(dx: -320, dy: -320)
        guard sanityFrame.intersects(convertedBounds) else {
            return nil
        }

        if let accessibilityElementBounds,
           let convertedElementBounds = resolvedElementRect(fromAccessibilityBounds: accessibilityElementBounds) {
            let expandedElementBounds = convertedElementBounds.insetBy(dx: -24, dy: -24)
            guard expandedElementBounds.intersects(convertedBounds) else {
                return nil
            }
        }

        return convertedBounds.integral
    }

    private func resolvedElementRect(fromAccessibilityBounds bounds: CGRect) -> CGRect? {
        guard isFinite(bounds),
              bounds.width > 0,
              bounds.height > 0,
              var convertedBounds = appKitRect(fromAccessibilityRect: bounds) else {
            return nil
        }

        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { partialResult, screen in
            partialResult = partialResult.union(screen.frame)
        }
        let sanityFrame = desktopFrame.insetBy(dx: -320, dy: -320)
        guard sanityFrame.intersects(convertedBounds) else {
            return nil
        }

        if convertedBounds.width < 24 {
            convertedBounds.size.width = 24
        }

        if convertedBounds.height < 24 {
            convertedBounds.size.height = 24
        }

        return convertedBounds.integral
    }

    private func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
        rect.origin.y.isFinite &&
        rect.size.width.isFinite &&
        rect.size.height.isFinite
    }

    private func appKitRect(fromAccessibilityRect accessibilityRect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return SnippetExpansionPolicy.appKitRect(
            from: accessibilityRect, primaryScreenHeight: primary.frame.height)
    }

    private func ensureObservationTargetCurrent() {
        guard let frontmostApplication = frontmostApplication() else {
            stopObservingActiveTarget()
            return
        }

        if observedApplication?.processIdentifier == frontmostApplication.processIdentifier {
            refreshObservedElements()
            return
        }

        stopObservingActiveTarget()
        observedApplication = frontmostApplication
        observedApplicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        activateAccessibilityIfNeeded(for: frontmostApplication)
        refreshObservedElements()

        guard let observedApplicationElement else {
            logObserver("Skipped AX observer setup because the app element was unavailable.")
            return
        }

        var observer: AXObserver?
        let observerError = AXObserverCreate(
            frontmostApplication.processIdentifier,
            { _, element, notification, refcon in
                guard let refcon else { return }
                let controller = Unmanaged<SnippetExpansionController>.fromOpaque(refcon).takeUnretainedValue()
                controller.handleAXNotification(notification as String, element: element)
            },
            &observer
        )

        guard observerError == .success, let observer else {
            logObserver("Failed to create AX observer for \(frontmostApplication.localizedName ?? "unknown") with error=\(describe(observerError))")
            return
        }

        axObserver = observer
        axObserverSource = AXObserverGetRunLoopSource(observer)

        if let axObserverSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), axObserverSource, .commonModes)
        }

        registerAppNotifications(observer, for: observedApplicationElement)
        registerFocusedWindowNotifications()
        registerFocusedElementNotifications()

        logObserver("Observing \(frontmostApplication.localizedName ?? "unknown") bundle=\(frontmostApplication.bundleIdentifier ?? "unknown") pid=\(frontmostApplication.processIdentifier)")
    }

    private func stopObservingActiveTarget() {
        unregisterFocusedElementNotifications()
        unregisterFocusedWindowNotifications()

        if let axObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), axObserverSource, .commonModes)
            self.axObserverSource = nil
        }

        axObserver = nil
        observedApplication = nil
        observedApplicationElement = nil
        observedFocusedWindow = nil
        observedFocusedElement = nil
        lastObserverLogKey = nil
        lastActivationLogKey = nil
    }

    private func refreshObservedElements() {
        if let observedApplicationElement {
            observedFocusedWindow = focusedWindow(in: observedApplicationElement)
        } else {
            observedFocusedWindow = nil
        }

        observedFocusedElement = focusedElement()
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard isSessionActive else { return }

            switch notification {
            case kAXFocusedUIElementChangedNotification:
                sessionAnchorRect = nil
                sessionAnchorStrategy = nil
                unregisterFocusedElementNotifications()
                refreshObservedElements()
                registerFocusedElementNotifications()
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                sessionAnchorRect = nil
                sessionAnchorStrategy = nil
                unregisterFocusedWindowNotifications()
                unregisterFocusedElementNotifications()
                refreshObservedElements()
                registerFocusedWindowNotifications()
                registerFocusedElementNotifications()
            case kAXMovedNotification, kAXResizedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification:
                refreshObservedElements()
            default:
                refreshObservedElements()
            }

            let notificationDescription = notification
            let role = stringAttribute(kAXRoleAttribute as CFString, for: element) ?? "unknown"
            logObserver("Received \(notificationDescription) role=\(role)")
            refreshSuggestionsAsync()
        }
    }

    private func registerAppNotifications(_ observer: AXObserver, for applicationElement: AXUIElement) {
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification
        ] {
            addNotification(notification, to: applicationElement, observer: observer)
        }
    }

    private func registerFocusedWindowNotifications() {
        guard let axObserver, let observedFocusedWindow else { return }
        for notification in [kAXMovedNotification, kAXResizedNotification] {
            addNotification(notification, to: observedFocusedWindow, observer: axObserver)
        }
    }

    private func unregisterFocusedWindowNotifications() {
        guard let axObserver, let observedFocusedWindow else { return }
        for notification in [kAXMovedNotification, kAXResizedNotification] {
            _ = AXObserverRemoveNotification(axObserver, observedFocusedWindow, notification as CFString)
        }
    }

    private func registerFocusedElementNotifications() {
        guard let axObserver, let observedFocusedElement else { return }
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            addNotification(notification, to: observedFocusedElement, observer: axObserver)
        }
    }

    private func unregisterFocusedElementNotifications() {
        guard let axObserver, let observedFocusedElement else { return }
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            _ = AXObserverRemoveNotification(axObserver, observedFocusedElement, notification as CFString)
        }
    }

    private func addNotification(_ notification: String, to element: AXUIElement, observer: AXObserver) {
        let error = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        switch error {
        case .success, .notificationAlreadyRegistered:
            return
        case .notificationUnsupported:
            logObserver("Notification \(notification) unsupported for current AX element.")
        default:
            logObserver("Failed to register notification \(notification) error=\(describe(error))")
        }
    }

    private func activateAccessibilityIfNeeded(for application: NSRunningApplication) {
        guard let observedApplicationElement else {
            return
        }

        guard let mode = accessibilityActivationMode(for: application.bundleIdentifier) else {
            return
        }

        let logKey = "\(application.processIdentifier)-\(mode.rawValue)"
        guard lastActivationLogKey != logKey else {
            return
        }
        lastActivationLogKey = logKey

        switch mode {
        case .chromiumEnhancedUI:
            guard let targetWindow = focusedWindow(in: observedApplicationElement) else {
                logObserver("Skipped Chromium accessibility activation because no focused window was available.")
                return
            }

            let error = AXUIElementSetAttributeValue(
                targetWindow,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
            logObserver("Activated Chromium accessibility bundle=\(application.bundleIdentifier ?? "unknown") result=\(describe(error))")
        case .electronManualAccessibility:
            let error = AXUIElementSetAttributeValue(
                observedApplicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            logObserver("Activated Electron accessibility bundle=\(application.bundleIdentifier ?? "unknown") result=\(describe(error))")
        }
    }

    private func accessibilityActivationMode(for bundleIdentifier: String?) -> AccessibilityActivationMode? {
        guard let bundleIdentifier else {
            return nil
        }

        let chromiumBundles: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "org.chromium.Chromium",
            "company.thebrowser.Browser",
            "com.vivaldi.Vivaldi"
        ]
        if chromiumBundles.contains(bundleIdentifier) {
            return .chromiumEnhancedUI
        }

        let electronBundles: Set<String> = [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.VSCode",
            "notion.id",
            "com.figma.Desktop"
        ]
        if electronBundles.contains(bundleIdentifier) {
            return .electronManualAccessibility
        }

        return nil
    }

    private func axElementAttribute(_ attribute: CFString, for element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        return value as? String
    }

    private func logAnchorResolutionIfNeeded(_ resolution: AnchorResolution) {
        guard Diagnostics.enabled else { return }
        let logKey = [
            resolution.strategy.rawValue,
            resolution.bundleIdentifier ?? "unknown",
            resolution.focusedRole ?? "unknown",
            resolution.focusedSubrole ?? "none"
        ].joined(separator: "|")

        guard lastAnchorLogKey != logKey else {
            return
        }
        lastAnchorLogKey = logKey

        let strategySuffix = sessionAnchorStrategy.map { " previous=\($0.rawValue)" } ?? ""
        Diagnostics(category: "snippets").info(
            "[clippie snippet] anchor strategy=\(resolution.strategy.rawValue)\(strategySuffix) " +
            "bundle=\(resolution.bundleIdentifier ?? "unknown") pid=\(resolution.processID ?? 0) " +
            "role=\(resolution.focusedRole ?? "unknown") subrole=\(resolution.focusedSubrole ?? "none") " +
            "rect=\(NSStringFromRect(resolution.rect))"
        )
    }

    private func logObserver(_ message: String) {
        guard Diagnostics.enabled else { return }
        guard let observedApplication else {
            Diagnostics(category: "snippets").info(message)
            return
        }

        let logKey = "\(observedApplication.processIdentifier)|\(message)"
        guard lastObserverLogKey != logKey else {
            return
        }
        lastObserverLogKey = logKey

        Diagnostics(category: "snippets").info(
            "[clippie snippet] \(message) " +
            "bundle=\(observedApplication.bundleIdentifier ?? "unknown") pid=\(observedApplication.processIdentifier)"
        )
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegalArgument"
        case .invalidUIElement:
            return "invalidUIElement"
        case .invalidUIElementObserver:
            return "invalidUIElementObserver"
        case .cannotComplete:
            return "cannotComplete"
        case .attributeUnsupported:
            return "attributeUnsupported"
        case .actionUnsupported:
            return "actionUnsupported"
        case .notificationUnsupported:
            return "notificationUnsupported"
        case .notImplemented:
            return "notImplemented"
        case .notificationAlreadyRegistered:
            return "notificationAlreadyRegistered"
        case .notificationNotRegistered:
            return "notificationNotRegistered"
        case .apiDisabled:
            return "apiDisabled"
        case .noValue:
            return "noValue"
        case .parameterizedAttributeUnsupported:
            return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:
            return "notEnoughPrecision"
        default:
            return "unknown(\(error.rawValue))"
        }
    }

    private func playInsertionSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    private var shouldCommitSnippetSelectionOnReturn: Bool {
        guard let activeQuery else {
            return hasNavigatedSuggestions
        }

        return !activeQuery.isEmpty || hasNavigatedSuggestions
    }
}

private enum AnchorStrategy: String {
    case caretBounds
    case textMarkerCaret
    case textElement
    case focusedWindow
    case cachedPosition
    case pointer
    case screenCenter

    var isCaret: Bool { self == .caretBounds || self == .textMarkerCaret }
}

private struct AnchorResolution {
    let rect: CGRect
    let strategy: AnchorStrategy
    let bundleIdentifier: String?
    let processID: pid_t?
    let focusedRole: String?
    let focusedSubrole: String?
}

private enum AccessibilityActivationMode: String {
    case chromiumEnhancedUI
    case electronManualAccessibility
}

@MainActor
private final class SnippetSuggestionWindowController: NSWindowController {
    private let hostingView: NSHostingView<SnippetSuggestionListView>
    private let metrics: () -> InterfaceMetrics
    private let onActivateSuggestion: (Int) -> Void
    private let onHoverSuggestion: (Int) -> Void
    private let overlay = SnippetBackdropController()

    init(
        metrics: @escaping () -> InterfaceMetrics,
        onActivateSuggestion: @escaping (Int) -> Void,
        onHoverSuggestion: @escaping (Int) -> Void
    ) {
        self.metrics = metrics
        self.onActivateSuggestion = onActivateSuggestion
        self.onHoverSuggestion = onHoverSuggestion
        hostingView = NSHostingView(rootView: SnippetSuggestionListView(
            suggestions: [], selectedIndex: 0, metrics: metrics(),
            onActivateSuggestion: onActivateSuggestion, onHoverSuggestion: onHoverSuggestion))
        hostingView.sizingOptions = []
        let panel = SnippetPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("snippet-suggestions")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.contentView = hostingView
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { window?.isVisible == true }

    func show(
        suggestions: [SnippetSuggestion], selectedIndex: Int, anchorRect: CGRect, anchorStrategy: AnchorStrategy
    ) {
        update(suggestions: suggestions, selectedIndex: selectedIndex)
        let metrics = metrics()
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorRect.midX, y: anchorRect.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame.insetBy(dx: metrics.spacing.md, dy: metrics.spacing.md)
        let size = CGSize(
            width: min(popupWidth(for: suggestions, metrics: metrics), visibleFrame.width),
            height: min(CGFloat(min(Theme.Size.snippetVisibleRows, suggestions.count)) * metrics.size.snippetRowHeight
                + metrics.spacing.sm * 2, visibleFrame.height))
        let origin = SnippetExpansionPolicy.popupOrigin(
            anchor: anchorRect, size: size, visibleFrame: visibleFrame,
            centered: anchorStrategy == .screenCenter, gap: metrics.spacing.md)
        window?.setFrame(CGRect(origin: origin, size: size), display: true)
        if anchorStrategy.isCaret {
            overlay.hide()
        } else {
            overlay.show(on: screen, popupFrame: CGRect(origin: origin, size: size))
        }
        window?.orderFrontRegardless()
    }

    private func popupWidth(for suggestions: [SnippetSuggestion], metrics: InterfaceMetrics) -> CGFloat {
        let triggerFont = metrics.typography.textNSFont(.body, weight: .bold)
        let detailFont = metrics.typography.textNSFont(.body)
        let contentWidth = suggestions.map { suggestion in
            (suggestion.isDraft ? triggerFont.pointSize + metrics.spacing.sm : 0)
                + (suggestion.trigger as NSString).size(withAttributes: [.font: triggerFont]).width
                + (suggestion.detail as NSString).size(withAttributes: [.font: detailFont]).width
                + metrics.spacing.md
        }.max() ?? 0
        return min(metrics.size.snippetMaximumWidth,
                   max(metrics.size.snippetMinimumWidth,
                       ceil(contentWidth) + metrics.spacing.md * 2 + metrics.spacing.sm * 2))
    }

    func update(suggestions: [SnippetSuggestion], selectedIndex: Int) {
        hostingView.rootView = SnippetSuggestionListView(
            suggestions: suggestions, selectedIndex: selectedIndex, metrics: metrics(),
            onActivateSuggestion: onActivateSuggestion, onHoverSuggestion: onHoverSuggestion)
    }

    func hide() {
        window?.orderOut(nil)
        overlay.hide()
    }
}

private final class SnippetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SnippetDraft {
    let trigger: String
    let content: String?
}

private enum SnippetSuggestion: Identifiable {
    case snippet(Snippet)
    case draft(SnippetDraft)

    var id: String {
        switch self {
        case .snippet(let snippet): snippet.id.uuidString
        case .draft: "draft"
        }
    }

    var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }

    var trigger: String {
        switch self {
        case .snippet(let snippet): snippet.trigger
        case .draft(let draft): draft.trigger
        }
    }

    var detail: String {
        switch self {
        case .snippet(let snippet):
            return (snippet.title.isEmpty ? snippet.content : snippet.title).collapsedForSuggestion
        case .draft(let draft):
            guard let content = draft.content else { return "New snippet" }
            return content.isEmpty ? "Type text to save" : content.collapsedForSuggestion
        }
    }
}

private struct SnippetSuggestionListView: View {
    let suggestions: [SnippetSuggestion]
    let selectedIndex: Int
    let metrics: InterfaceMetrics
    let onActivateSuggestion: (Int) -> Void
    let onHoverSuggestion: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion, index: index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedIndex) {
                revealSelection(using: proxy)
            }
            .onChange(of: suggestions.map(\.id)) {
                revealSelection(using: proxy)
            }
            .onAppear { revealSelection(using: proxy) }
        }
        .padding(metrics.spacing.sm)
        .background(HUDGlassBackground(cornerRadius: metrics.radius.menuPanel))
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.menuPanel, style: .continuous))
        .environment(\.metrics, metrics)
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        guard suggestions.indices.contains(selectedIndex) else { return }
        proxy.scrollTo(suggestions[selectedIndex].id)
    }

    private func suggestionRow(_ suggestion: SnippetSuggestion, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return HStack(spacing: metrics.spacing.md) {
            HStack(spacing: metrics.spacing.sm) {
                if suggestion.isDraft {
                    Image(systemName: "plus")
                        .accessibilityLabel("New snippet")
                }
                Text(suggestion.trigger)
            }
            .font(metrics.typography.rowTitle.bold())
            .foregroundStyle(isSelected ? Theme.Colors.snippetSelectedText : Theme.Colors.textPrimary)
            .layoutPriority(1)
            Text(suggestion.detail)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(isSelected ? Theme.Colors.snippetSelectedText : Theme.Colors.textSecondary)
        }
        .lineLimit(1)
        .padding(.horizontal, metrics.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: metrics.size.snippetRowHeight)
        .background(isSelected ? Theme.Colors.snippetSelection : .clear,
                    in: RoundedRectangle(cornerRadius: metrics.radius.snippetSelection, style: .continuous))
        .contentShape(Rectangle())
        .onHover { if $0 { onHoverSuggestion(index) } }
        .onTapGesture { onActivateSuggestion(index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivateSuggestion(index) }
    }
}

private extension String {
    var collapsedForSuggestion: String {
        prefix(200).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
private final class SnippetBackdropController {
    private var window: SnippetPanel?
    private var hideTask: Task<Void, Never>?

    func show(on screen: NSScreen, popupFrame: CGRect) {
        hideTask?.cancel()
        hideTask = nil
        let panel: SnippetPanel
        if let window {
            panel = window
        } else {
            panel = SnippetPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            window = panel
        }
        let focus = UnitPoint(
            x: (popupFrame.midX - screen.frame.minX) / screen.frame.width,
            y: (screen.frame.maxY - popupFrame.midY) / screen.frame.height)
        let hosting = NSHostingView(rootView: SnippetBackdropView(focus: focus))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        setOpacity(1, on: panel)
    }

    func hide() {
        guard let window, window.isVisible, hideTask == nil else { return }
        setOpacity(0, on: window)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.orderOut(nil)
            return
        }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Theme.Duration.exit)) } catch { return }
            guard let self else { return }
            self.window?.orderOut(nil)
            self.hideTask = nil
        }
    }

    private func setOpacity(_ opacity: CGFloat, on window: NSWindow) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.alphaValue = opacity
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Duration.exit
                window.animator().alphaValue = opacity
            }
        }
    }

    deinit { hideTask?.cancel() }
}

private struct SnippetBackdropView: View {
    let focus: UnitPoint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            if reduceTransparency {
                Theme.Colors.snippetFallbackDim
            } else {
                RadialGradient(colors: [Theme.Colors.snippetFallbackFocus, Theme.Colors.snippetFallbackDim],
                               center: focus, startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
