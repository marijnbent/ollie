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
        guard case .restored = lease.restoreIfOwned() else { preconditionFailure("restore failed") }
        precondition(board.string(forType: .string) == "original")
        let superseded = TemporaryPasteboardLease.begin(text: "temporary", pasteboard: board)!
        board.clearContents()
        board.setString("new user copy", forType: .string)
        precondition(superseded.restoreIfOwned() == .superseded)
        precondition(board.string(forType: .string) == "new user copy")

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
