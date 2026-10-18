import AppKit

enum Paster { static let ollieEventTag: Int64 = 0x54494E59 }

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

        type(">")
        type("f")
        check("multi-character completion is consumed", type("i"))
        check("longer trigger preserves replacement whitespace", editor.string == "Keep this pr+mergexInvestigate. ")

        try store.saveSnippet(title: "", trigger: "pp", content: "longer")
        type(">")
        check("ambiguous exact match remains literal", !type("p", keyCode: 35))
        check("longer trigger consumes only its final key", type("p", keyCode: 35))
        check("longer prefix wins without leftover keys", editor.string.hasSuffix("Investigate. longer"))

        type(">")
        type("f")
        type("x")
        check("backspace is forwarded", !type("\u{8}", keyCode: 51))
        check("completion after backspace is consumed", type("i"))
        check("backspace keeps the query aligned with the editor", editor.string.hasSuffix("longerInvestigate. "))

        type(">")
        check("generated input is ignored", !type("p", marker: Paster.ollieEventTag))
        check("generated input does not expand", editor.string.hasSuffix(">p"))
        controller.stop()
        check("usage counts expansions once", store.exactTriggerMatch(for: "fi")?.usageCount == 2)

        print(failures == 0 ? "PASS: snippet event ordering" : "FAIL: \(failures) snippet checks")
        if failures > 0 { exit(1) }
    }

    private static func check(_ name: String, _ condition: Bool) {
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }
}
