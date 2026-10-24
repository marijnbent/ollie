import AppKit

@main
@MainActor
struct TextInjectionTests {
    static func main() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let lease = TemporaryPasteboardLease.begin(text: "replacement", pasteboard: board)!
        precondition(board.string(forType: .string) == "replacement")
        precondition(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        guard case .restored = lease.restoreIfOwned() else { preconditionFailure("restore failed") }
        precondition(board.string(forType: .string) == "original")
        let superseded = TemporaryPasteboardLease.begin(text: "temporary", pasteboard: board)!
        board.clearContents()
        board.setString("new user copy", forType: .string)
        precondition(superseded.restoreIfOwned() == .superseded)
        precondition(board.string(forType: .string) == "new user copy")

        let original = NSPasteboardItem()
        original.setString("rich clipboard", forType: .string)
        let richText = Data("{\\rtf1\\ansi rich clipboard}".utf8)
        original.setData(richText, forType: .rtf)
        board.clearContents()
        board.writeObjects([original])
        let pasteQueue = DeliveryQueue()
        let injector = TextInjector(deliveryQueue: pasteQueue, pasteboard: board, inlinePasteDelay: .zero)
        var posted: [CGEvent] = []
        var pasted: [String] = []
        var finished = false
        precondition(TextInjector.inlinePasteEvents(deleting: 3) != nil, "paste events can be constructed")
        precondition(PasteboardSnapshot(pasteboard: board) != nil, "rich clipboard can be preserved")
        precondition(injector.pasteInline("marijn@marijnbent.nl", deleting: 3, postEvent: { event in
            posted.append(event)
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9 {
                pasted.append(board.string(forType: .string) ?? "")
            }
        }, onFinished: { finished = true }))
        precondition(posted.filter { $0.type == .keyDown }.map {
            $0.getIntegerValueField(.keyboardEventKeycode)
        } == [51, 51, 51, 9])
        precondition(pasted == ["marijn@marijnbent.nl"] && !finished)
        precondition(!injector.pasteInline("overlap", deleting: 1, postEvent: { _ in
            preconditionFailure("overlapping paste posted input")
        }, onFinished: {}))
        await pasteQueue.drain()
        precondition(finished && !injector.isDelivering)
        precondition(board.string(forType: .string) == "rich clipboard")
        precondition(board.data(forType: .rtf) == richText)
        precondition(injector.pasteInline("temporary", deleting: 0, postEvent: { _ in }, onFinished: {}))
        board.clearContents()
        board.setString("copied during paste", forType: .string)
        await pasteQueue.drain()
        precondition(board.string(forType: .string) == "copied during paste")
        let prepared = injector.prepareInlinePaste()
        precondition(prepared?.changeCount == board.changeCount, "prepared snapshot matches the clipboard")
        precondition(injector.pasteInline("lent", deleting: 0, prepared: prepared, postEvent: { _ in }, onFinished: {}))
        await pasteQueue.drain()
        precondition(board.string(forType: .string) == "copied during paste", "prepared snapshot is restored")
        board.clearContents()
        board.setString("copied after preparing", forType: .string)
        precondition(injector.pasteInline("lent", deleting: 0, prepared: prepared, postEvent: { _ in }, onFinished: {}))
        await pasteQueue.drain()
        precondition(board.string(forType: .string) == "copied after preparing", "stale snapshot is ignored")

        let text = "a👨‍👩‍👧‍👦é日本語"
        let chunks = UnicodeTypingChunk.split(text)
        precondition(chunks.allSatisfy { $0.count <= 4 })
        precondition(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
        let multiline = "first\n\tsecond\nlast"
        let multilineChunks = UnicodeTypingChunk.split(multiline)
        precondition(String(decoding: multilineChunks.flatMap { $0 }, as: UTF16.self) == multiline)
        precondition(multilineChunks.filter { $0.contains(10) || $0.contains(9) }.allSatisfy { $0.count == 1 })
        precondition(TextReplacementPolicy.confirmsReplacement(
            originalValue: "one two", replacementRange: NSRange(location: 4, length: 3),
            insertedText: "three", observedValue: "one three"))
        precondition(!TextReplacementPolicy.confirmsReplacement(
            originalValue: "one two", replacementRange: NSRange(location: 4, length: 3),
            insertedText: "three", observedValue: "one two"))

        precondition(TextReplacementPolicy.triggerRange(
            ">fi", in: "Before >Fi", selectedRange: NSRange(location: 10, length: 0))
            == NSRange(location: 7, length: 3))
        precondition(TextReplacementPolicy.triggerRange(
            ">fi", in: "Different", selectedRange: NSRange(location: 9, length: 0)) == nil)
        precondition(TextReplacementPolicy.triggerRange(
            ">fi", in: ">fi", selectedRange: NSRange(location: 0, length: 3)) == nil)

        let queue = DeliveryQueue()
        var deliveries: [Int] = []
        queue.enqueue {
            await Task.yield()
            deliveries.append(1)
        }
        queue.enqueue { deliveries.append(2) }
        await queue.drain()
        precondition(deliveries == [1, 2] && queue.isIdle)
        var confirmed = 0
        var failed = 0
        let completion = DeliveryCompletion(onDelivered: { confirmed += 1 }, onFailed: { failed += 1 })
        completion.confirm()
        completion.settle()
        precondition(confirmed == 1 && failed == 0)
        print("Text delivery checks passed")
    }
}
