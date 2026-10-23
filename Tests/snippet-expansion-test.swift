import AppKit

@main
@MainActor
struct SnippetExpansionTests {
    private static var failures = 0

    static func main() throws {
        _ = NSApplication.shared
        let name = "ollie.snippet-expansion-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SnippetStore(defaults: defaults)
        try store.saveSnippet(title: "", trigger: "p", content: "pr+merge")
        try store.saveSnippet(title: "", trigger: "fi", content: "Investigate. ")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        let injector = TextInjector(pasteboard: board, inlinePasteDelay: .zero)
        var replayed: [CGEvent] = []
        let controller = SnippetExpansionController(
            store: store, injector: injector, frontmostApplication: { nil }, replayEvent: { replayed.append($0) })
        defer { controller.stop() }
        let editor = NSTextView()
        var generated: [CGEvent] = []
        var visibleBeforePrefixInsertion = false

        func deliver(_ event: CGEvent) {
            guard event.type == .keyDown, let key = NSEvent(cgEvent: event) else { return }
            if key.keyCode == 9, key.modifierFlags.contains(.command) {
                editor.insertText(board.string(forType: .string) ?? "", replacementRange: editor.selectedRange())
            } else if key.keyCode == 51 {
                editor.deleteBackward(nil)
            } else {
                editor.keyDown(with: key)
            }
        }

        @discardableResult
        func type(_ text: String, keyCode: CGKeyCode = 0, marker: Int64 = 0, waitForPaste: Bool = true) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
            let characters = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            let forwarded = controller.handle(type: .keyDown, event: event) { replacement in
                generated.append(replacement)
                deliver(replacement)
            }
            if text == ">" {
                visibleBeforePrefixInsertion = NSApp.windows.contains {
                    $0.identifier?.rawValue == "snippet-suggestions" && $0.isVisible
                }
            }
            if let forwarded { deliver(forwarded.takeUnretainedValue()) }
            if waitForPaste {
                let deadline = Date().addingTimeInterval(1)
                while injector.isDelivering, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
            }
            return forwarded == nil
        }

        editor.string = "Keep this "
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        check("prefix is forwarded", !type(">"))
        check("completing key is consumed synchronously", type("p", keyCode: 35))
        check("short trigger preserves preceding text", editor.string == "Keep this pr+merge")
        check("short trigger deletes only the forwarded prefix", generated.filter {
            $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 51
        }.count == 1)
        check("replacement events are tagged with only the paste shortcut modified", generated.allSatisfy {
            $0.getIntegerValueField(.eventSourceUserData) == Paster.ollieEventTag
                && $0.flags == ($0.getIntegerValueField(.keyboardEventKeycode) == 9 ? .maskCommand : [])
        })
        check("short expansion posts exactly one paste", generated.filter {
            $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 9
        }.count == 1)
        check("expansion restores the previous clipboard", board.string(forType: .string) == "original clipboard")
        type("x")
        check("following keystroke stays after replacement", editor.string == "Keep this pr+mergex")

        type(" ")
        type(">")
        type("f")
        check("multi-character completion is consumed", type("i"))
        check("longer trigger preserves replacement whitespace", editor.string == "Keep this pr+mergex Investigate. ")

        try store.saveSnippet(title: "", trigger: "pp", content: "longer")
        type(" ")
        type(">")
        check("ambiguous exact match remains literal", !type("p", keyCode: 35))
        check("longer trigger consumes only its final key", type("p", keyCode: 35))
        check("longer prefix wins without leftover keys", editor.string.hasSuffix("Investigate.  longer"))

        type(" ")
        type(">")
        type("f")
        type("x")
        check("backspace is forwarded", !type("\u{8}", keyCode: 51))
        check("completion after backspace is consumed", type("i"))
        check("backspace keeps the query aligned with the editor", editor.string.hasSuffix("longer Investigate. "))

        type(" ")
        type(">")
        check("generated input is ignored", !type("p", marker: Paster.ollieEventTag))
        check("generated input does not expand", editor.string.hasSuffix(">p"))
        type(" ")

        func typeText(_ text: String) { for character in text { type(String(character)) } }
        typeText(">sig")
        check("space after an unknown trigger is forwarded", !type(" ", keyCode: 49))
        typeText("Hi thera")
        type("\u{8}", keyCode: 51)
        type("e")
        check("Return saves the inline draft", type("\r", keyCode: 36))
        check("inline draft becomes a snippet", store.exactTriggerMatch(for: "sig")?.content == "Hi there")
        check("inline draft replaces its trigger", editor.string.hasSuffix(">p Hi there"))
        type(" ")
        typeText(">tmp ")
        type("\u{8}", keyCode: 51)
        typeText("x ")
        check("backspace over the draft space returns to the query", editor.string.hasSuffix(">tmpx "))
        check("Escape abandons the draft", type("", keyCode: 53))
        check("abandoned draft saves nothing", store.exactTriggerMatch(for: "tmp") == nil
            && store.exactTriggerMatch(for: "tmpx") == nil)
        type(" ")
        type(">")
        type("p")
        type(" ")
        check("space after an ambiguous exact trigger stays literal", editor.string.hasSuffix(">p "))
        typeText(">zz ")
        check("Return on an empty draft passes through", !type("\r", keyCode: 36))
        check("empty draft saves nothing", store.exactTriggerMatch(for: "zz") == nil)
        let draftValue = "Hi >Sig  Best regards"
        let draft = SnippetExpansionPolicy.draft(
            in: draftValue, selectedRange: NSRange(location: draftValue.utf16.count, length: 0), trigger: "sig")
        check("AX draft keeps typed casing", draft?.typed == ">Sig  Best regards")
        check("AX draft content follows the trigger", draft?.content == " Best regards")
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        type(" ")
        typeText(">merge")
        settle()
        check("content-only matches leave only the create row", type("\r", keyCode: 36))
        check("create row inserts the draft space", editor.string.hasSuffix(">merge "))
        typeText("Merged")
        check("Return saves after a content match", type("\r", keyCode: 36))
        check("content match no longer blocks creation", store.exactTriggerMatch(for: "merge")?.content == "Merged")
        type(" ")
        typeText(">f")
        settle()
        check("create row follows trigger matches", type("", keyCode: 125))
        check("Return on the trailing create row starts a draft", type("\r", keyCode: 36))
        check("trailing create row inserts the draft space", editor.string.hasSuffix(">f "))
        type("", keyCode: 53)
        for snippet in store.snippets where ["sig", "merge"].contains(snippet.trigger) {
            store.deleteSnippet(id: snippet.id)
        }
        type(" ")
        let longText = String(repeating: "  日本語 👩🏽‍💻 café\n\tSecond line\n", count: 20) + "  "
        try store.saveSnippet(title: "Long signature", trigger: "long", content: longText)
        let before = editor.string
        let beforeLongEvents = generated.count
        type(">")
        type("l")
        type("o")
        type("n")
        check("long completion is consumed", type("g"))
        check("long multiline Unicode arrives intact", editor.string == before + longText)
        check("snippet text never uses Unicode key events", generated.dropFirst(beforeLongEvents).filter {
            $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 0
        }.isEmpty)
        check("title-only matches are excluded", store.matches(for: "signature").isEmpty)
        try store.saveSnippet(title: "longer title", trigger: "other", content: "Title-only match")
        let exact = store.exactTriggerMatch(for: "long")!
        check("title-only hits do not block auto-expansion", SnippetExpansionPolicy.shouldAutoExpand(
            exact, among: store.matches(for: "long")))
        for prefix in ["-", "=", "a", "<div"] {
            type(" ")
            for character in prefix { type(String(character)) }
            type(">")
            check("nonboundary \(prefix) does not expand", !type("p"))
        }
        for prefix in ["", " ", "\n", "\t", "👩🏽‍💻 "] {
            check("AX boundary \(prefix.debugDescription)", SnippetExpansionPolicy.canStartSession(
                value: prefix, selectedRange: NSRange(location: prefix.utf16.count, length: 0),
                previousCharacter: "a"))
        }
        for prefix in ["-", "=", "a", "<div", "👩🏽‍💻"] {
            check("AX rejects nonboundary", !SnippetExpansionPolicy.canStartSession(
                value: prefix, selectedRange: NSRange(location: prefix.utf16.count, length: 0),
                previousCharacter: " "))
        }
        check("fallback whitespace", SnippetExpansionPolicy.canStartSession(
            value: nil, selectedRange: nil, previousCharacter: "\n"))
        check("fallback operator", !SnippetExpansionPolicy.canStartSession(
            value: nil, selectedRange: nil, previousCharacter: "-"))
        let primaryHeight: CGFloat = 900
        let primaryCaret = CGRect(x: 20, y: 100, width: 1, height: 20)
        check("primary conversion ignores taller secondary", SnippetExpansionPolicy.appKitRect(
            from: primaryCaret, primaryScreenHeight: primaryHeight) == CGRect(x: 20, y: 780, width: 1, height: 20))
        let aboveCaret = CGRect(x: 30, y: -500, width: 1, height: 20)
        check("display above primary converts negative AX y", SnippetExpansionPolicy.appKitRect(
            from: aboveCaret, primaryScreenHeight: primaryHeight) == CGRect(x: 30, y: 1380, width: 1, height: 20))
        let visible = CGRect(x: -1000, y: 900, width: 1000, height: 1500)
        let size = CGSize(width: 580, height: 200)
        let origin = SnippetExpansionPolicy.popupOrigin(
            anchor: CGRect(x: -10, y: 910, width: 1, height: 20), size: size,
            visibleFrame: visible, centered: false, gap: 8)
        check("popup flips above and clamps on secondary", origin == CGPoint(x: -580, y: 938))
        check("popup fits visible frame", visible.contains(CGRect(origin: origin, size: size)))
        controller.stop()
        check("usage counts expansions once", store.exactTriggerMatch(for: "fi")?.usageCount == 2)

        func popup() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "snippet-suggestions" }
        }

        func waitForPopup() {
            let deadline = Date().addingTimeInterval(1)
            while popup()?.isVisible != true, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }

        type(" ")
        type(">")
        check("prefix insertion precedes the first display", !visibleBeforePrefixInsertion)
        waitForPopup()
        check("bare prefix opens without AX notifications", popup()?.isVisible == true)
        let ranked = store.matches(for: "")
        check("popup hugs fewer than six rows", popup()?.frame.height ==
            CGFloat(ranked.count) * Theme.Size.snippetRowHeight + Theme.Spacing.sm * 2)
        check("empty query ranks frequent snippets first", ranked.first?.trigger == "fi")
        check("empty query breaks equal usage by recency", ranked.firstIndex {
            $0.trigger == "long"
        }! < ranked.firstIndex { $0.trigger == "p" }!)
        check("empty query Return passes through without navigation", !type("\r", keyCode: 36))
        check("Return ends the empty session", popup()?.isVisible == false)
        type(" ")
        type(">")
        let beforeTab = String(editor.string.dropLast())
        check("Tab accepts the top empty-query suggestion", type("\t", keyCode: 48))
        check("Tab inserts the highest-ranked snippet", editor.string == beforeTab + ranked[0].content)
        check("Tab hides the popup", popup()?.isVisible == false)

        type(" ")
        type(">")
        let nextRanked = store.matches(for: "")
        check("Down navigates the empty-query list", type("", keyCode: 125))
        check("Return accepts after arrow navigation", type("\r", keyCode: 36))
        check("arrow selection inserts the second ranked snippet", editor.string.hasSuffix(nextRanked[1].content))
        type(" ")
        type(">")
        check("Up navigates at the first empty-query row", type("", keyCode: 126))
        check("Return accepts after Up at the first row", type("\r", keyCode: 36))
        type(" ")
        type(">")
        check("Escape dismisses the empty-query list", type("", keyCode: 53))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check("Escape cancels the pending display", popup()?.isVisible == false)
        check("Return after Escape passes through", !type("\r", keyCode: 36))
        type(" ")
        type(">")
        check("deleting the bare prefix passes through", !type("\u{8}", keyCode: 51))
        check("deleting the bare prefix hides suggestions", popup()?.isVisible == false)
        check("Tab after deleting the prefix passes through", !type("\t", keyCode: 48))

        for index in 0..<8 {
            try store.saveSnippet(title: "Extra \(index)", trigger: "extra\(index)", content: "Extra content \(index)")
        }
        type(" ")
        type(">")
        waitForPopup()
        let allRanked = store.matches(for: "")
        check("popup height caps at six dense rows", popup()?.frame.height ==
            CGFloat(Theme.Size.snippetVisibleRows) * Theme.Size.snippetRowHeight + Theme.Spacing.sm * 2)
        check("popup width stays within compact bounds", popup().map {
            $0.frame.width >= Theme.Size.snippetMinimumWidth && $0.frame.width <= Theme.Size.snippetMaximumWidth
        } == true)
        for _ in 0..<7 { type("", keyCode: 125) }
        check("Return can accept a suggestion beyond the visible rows", type("\r", keyCode: 36))
        check("suggestions are not truncated to the visible row count", editor.string.hasSuffix(allRanked[7].content))
        for snippet in store.snippets where snippet.trigger != "p" { store.deleteSnippet(id: snippet.id) }
        type(" ")
        type(">")
        waitForPopup()
        check("one suggestion occupies exactly one row", popup()?.frame.height ==
            Theme.Size.snippetRowHeight + Theme.Spacing.sm * 2)
        check("short content hugs the minimum width", popup()?.frame.width == Theme.Size.snippetMinimumWidth)
        controller.stop()

        type(" ")
        type(">")
        controller.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check("stop cancels the pending display", popup()?.isVisible == false)

        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try store.saveSnippet(title: "", trigger: "mar", content: "marijn@marijnbent.nl")
        type(">")
        type("m")
        type("a")
        check("paste begins before further typing", type("r", waitForPaste: false))
        check("following typing waits while the clipboard is borrowed", type("x", waitForPaste: false))
        check("the entire email arrives before following input", editor.string == "marijn@marijnbent.nl")
        let deadline = Date().addingTimeInterval(1)
        while injector.isDelivering, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        check("one following key is replayed", replayed.count == 1)
        for event in replayed { deliver(event) }
        check("replayed typing follows the complete paste", editor.string == "marijn@marijnbent.nlx")
        check("clipboard is restored before input resumes", board.string(forType: .string) == "original clipboard")

        let result = failures == 0 ? "PASS: snippet event ordering, insertion, boundaries, placement and empty-query suggestions"
            : "FAIL: \(failures) snippet checks"
        print(result)
        if failures > 0 { exit(1) }
    }

    private static func check(_ name: String, _ condition: Bool) {
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }
}
