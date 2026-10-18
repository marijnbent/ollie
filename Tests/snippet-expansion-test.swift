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
        let controller = SnippetExpansionController(store: store, frontmostApplication: { nil })
        defer { controller.stop() }
        let editor = NSTextView()
        var generated: [CGEvent] = []

        func deliver(_ event: CGEvent) {
            guard event.type == .keyDown, let key = NSEvent(cgEvent: event) else { return }
            if key.keyCode == 51 {
                editor.deleteBackward(nil)
            } else {
                editor.keyDown(with: key)
            }
        }

        @discardableResult
        func type(_ text: String, keyCode: CGKeyCode = 0, marker: Int64 = 0) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
            let characters = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            let forwarded = controller.handle(type: .keyDown, event: event) { replacement in
                generated.append(replacement)
                deliver(replacement)
            }
            if let forwarded { deliver(forwarded.takeUnretainedValue()) }
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
        check("replacement events are tagged and have no modifiers", generated.allSatisfy {
            $0.getIntegerValueField(.eventSourceUserData) == Paster.ollieEventTag && $0.flags.isEmpty
        })
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
        let longText = String(repeating: "  日本語 👩🏽‍💻 café\n\tSecond line\n", count: 20) + "  "
        try store.saveSnippet(title: "Long signature", trigger: "long", content: longText)
        let before = editor.string
        type(">")
        type("l")
        type("o")
        type("n")
        check("long completion is consumed", type("g"))
        check("long multiline Unicode arrives intact", editor.string == before + longText)
        check("Unicode events stay within the renderer limit", generated.filter {
            $0.type == .keyDown && $0.getIntegerValueField(.keyboardEventKeycode) == 0
        }.allSatisfy { event in
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
            return length <= UnicodeTypingChunk.maxUTF16Units
        })
        check("title matching is available", store.matches(for: "signature").first?.trigger == "long")
        try store.saveSnippet(title: "longer title", trigger: "other", content: "Title-only match")
        let exact = store.exactTriggerMatch(for: "long")!
        check("title-only hits do not block auto-expansion", SnippetExpansionPolicy.shouldAutoExpand(
            exact, among: store.expansionMatches(for: "long")))
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

        let result = failures == 0 ? "PASS: snippet event ordering, insertion, boundaries and placement"
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
