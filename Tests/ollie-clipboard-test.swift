import AppKit
import Foundation

enum Paster { static let ollieEventTag: Int64 = 0x465245444945 }

@main
@MainActor
struct OllieClipboardTests {
    private static var failures = 0

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(storageDirectory: directory)
        await store.load()
        let text = String(repeating: "large text ", count: 120_000) + "last-needle"
        let capture = ClipboardCapture(payload: .text(text), sourceApp: "Fixture", sourceBundleIdentifier: nil)
        let captured = try ClipboardWatcher.process(capture, previous: nil, storage: store.storage)!
        check("large text remains file backed", captured.0.textFilename != nil && captured.0.textContent!.count == 500)
        check("identical captures deduplicate", try ClipboardWatcher.process(capture, previous: captured.1, storage: store.storage) == nil)
        store.add(captured.0)
        let inline = ClipboardItem.text("inline", timestamp: Date())
        store.add(inline)
        store.delete(inline)
        check("queued snapshots flush", await store.flush())
        let reopened = ClipboardStore(storageDirectory: directory)
        await reopened.load()
        check("latest snapshot survives reopen", reopened.items == [captured.0])
        check("full text paste preserves every byte", try await reopened.storage.loadActionText(for: captured.0) == text)
        check("search sees beyond preview", reopened.storage.search(reopened.items, normalizedQuery: "last-needle")?.matches.count == 1)
        reopened.delete(captured.0)
        check("delete persists", await reopened.flush())
        check("unreferenced payload removed after commit", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("texts").appendingPathComponent(captured.0.textFilename!).path))

        let outside = directory.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let texts = directory.appendingPathComponent("texts")
        try FileManager.default.createSymbolicLink(at: texts.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        check("path traversal rejected", (try? ClipboardStorage.contentURL("../outside.txt", in: texts)) == nil)
        check("symlink escape rejected", (try? ClipboardStorage.contentURL("escape.txt", in: texts)) == nil)

        let session = ClipboardSearchSession()
        let alpha = ClipboardItem.text("alpha needle", timestamp: Date())
        let beta = ClipboardItem.text("beta needle", timestamp: Date())
        session.search("alpha", items: [alpha, beta], storage: reopened.storage)
        session.search("beta", items: [alpha, beta], storage: reopened.storage)
        check("new search removes stale actionable rows", session.items.isEmpty)
        for _ in 0..<100 where session.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        check("latest search wins", session.items == [beta] && session.query == "beta")
        session.search("beta", items: [beta], storage: reopened.storage)
        check("same-query refresh retains the visible selection", session.items == [beta])
        session.search("beta", items: [], storage: reopened.storage)
        check("same-query refresh removes deleted rows immediately", session.items.isEmpty)
        session.search("alpha", items: [alpha, beta], storage: reopened.storage)
        session.search("", items: [beta, alpha], storage: reopened.storage)
        try await Task.sleep(for: .milliseconds(100))
        check("clearing search cancels pending results", session.items == [beta, alpha])
        session.search("alpha", items: [alpha, beta], storage: reopened.storage)
        session.cancel()
        try await Task.sleep(for: .milliseconds(100))
        check("closed session cannot apply late results", session.items.isEmpty && !session.isSearching)

        let fixture = NSImage(size: NSSize(width: 700, height: 160), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Ollie OCR fixture 2147" as NSString).draw(at: NSPoint(x: 30, y: 65), withAttributes: [
                .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
            ])
            return true
        }
        let recognized = await OCRService.recognizeText(from: fixture)
        check("OCR recognizes image text", recognized?.contains("Ollie OCR fixture 2147") == true)
        let filename = reopened.storage.saveImage(fixture.tiffRepresentation!)!
        let imageItem = ClipboardItem.image(filename: filename, timestamp: Date())
        reopened.add(imageItem)
        reopened.setOCRText(recognized ?? "", for: imageItem)
        check("OCR persists", await reopened.flush())
        let restoredImage = try reopened.storage.readHistory().first { $0.id == imageItem.id }
        check("OCR survives reopen", restoredImage?.ocrText == recognized)
        session.search("2147", items: reopened.items, storage: reopened.storage)
        for _ in 0..<100 where session.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        check("extracted text is searchable", session.items.first?.id == imageItem.id)
        reopened.setOCRText("refreshed extraction", for: imageItem)
        session.search("2147", items: reopened.items, storage: reopened.storage)
        for _ in 0..<100 where session.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        check("OCR refresh replaces searchable text", session.items.isEmpty)

        let history = directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: history)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        reopened.add(.text("retry me", timestamp: Date()))
        check("failed save is visible", !(await reopened.flush()) && reopened.error != nil)
        try FileManager.default.removeItem(at: history)
        check("save retry recovers pending data", await reopened.flush())
        check("retry saved exact snapshot", try reopened.storage.readHistory() == reopened.items)

        let damaged = Data("damaged history".utf8)
        try damaged.write(to: history)
        let unreadable = ClipboardStore(storageDirectory: directory)
        await unreadable.load()
        unreadable.add(.text("must not replace", timestamp: Date()))
        let didFlushDamaged = await unreadable.flush()
        check("failed load cannot overwrite original", try !didFlushDamaged && Data(contentsOf: history) == damaged)

        var tracker = PasteboardChangeTracker(currentChangeCount: 4)
        tracker.recordSelfWrite(changeCount: 5)
        check("own pasteboard write ignored", !tracker.shouldCapture(changeCount: 5))
        check("next external copy captured", tracker.shouldCapture(changeCount: 6))
        tracker.reset(changeCount: 9)
        check("resume does not capture paused content", !tracker.shouldCapture(changeCount: 9))
        await delayedPaste()
        try snippets()
        print(failures == 0 ? "Clipboard integration passed" : "\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func delayedPaste() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("selected history item", forType: .string)
        let changeCount = pasteboard.changeCount
        var pasteSent = false
        let pasted = await PasteController.pasteIfUnchanged(
            on: pasteboard, expectedChangeCount: changeCount, prepare: {}, isTargetActive: { true },
            sendPaste: { pasteSent = true; return true })
        check("unchanged clipboard permits paste", pasted && pasteSent)
        pasteSent = false
        let replaced = await PasteController.pasteIfUnchanged(
            on: pasteboard, expectedChangeCount: changeCount,
            prepare: {
                pasteboard.clearContents()
                pasteboard.setString("newer copy", forType: .string)
            }, isTargetActive: { true }, sendPaste: { pasteSent = true; return true })
        check("clipboard replacement prevents delayed paste", !replaced && !pasteSent)
        check("paste cancellation preserves the newer copy", pasteboard.string(forType: .string) == "newer copy")
        let preparedCount = pasteboard.changeCount
        let inactive = await PasteController.pasteIfUnchanged(
            on: pasteboard, expectedChangeCount: preparedCount, prepare: {}, isTargetActive: { false },
            sendPaste: { pasteSent = true; return true })
        check("changed target prevents delayed paste", !inactive && !pasteSent)
        var prepared = false
        let task = Task { @MainActor in
            await PasteController.pasteIfUnchanged(
                on: pasteboard, expectedChangeCount: preparedCount,
                prepare: { prepared = true }, isTargetActive: { true },
                sendPaste: { pasteSent = true; return true })
        }
        while !prepared { await Task.yield() }
        task.cancel()
        let cancelled = await task.value
        check("cancelled operation never sends paste", !cancelled && !pasteSent)
    }

    private static func snippets() throws {
        let name = "ollie.clipboard-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SnippetStore(defaults: defaults)
        try store.saveSnippet(title: "", trigger: ">addr", content: "Address ")
        try store.saveSnippet(title: "", trigger: "address", content: "Long Address")
        check("exact trigger outranks longer prefix", store.matches(for: "addr").first?.trigger == "addr")
        do {
            try store.saveSnippet(title: "", trigger: "addr", content: "duplicate")
            check("duplicate triggers rejected", false)
        } catch SnippetStoreError.duplicateTrigger { }
        check("trigger display uses greater-than", store.exactTriggerMatch(for: ">addr")?.displayTitle == ">addr")
        check("colon trigger input is rejected", !Snippet.isSupportedTriggerInput(":addr"))
        do {
            try store.saveSnippet(title: "", trigger: "empty", content: " \n")
            check("blank snippet text is rejected", false)
        } catch SnippetStoreError.emptyContent { }
        let reopened = SnippetStore(defaults: defaults)
        check("snippet text persists", reopened.snippets.count == 2 && reopened.exactTriggerMatch(for: "addr")?.content == "Address ")
        let damaged = Data("damaged snippets".utf8)
        defaults.set(damaged, forKey: "savedSnippets")
        let unreadable = SnippetStore(defaults: defaults)
        do {
            try unreadable.saveSnippet(title: "", trigger: "new", content: "must not replace")
            check("unreadable snippets reject edits", false)
        } catch SnippetStoreError.unreadableHistory { }
        check("unreadable snippets retained", defaults.data(forKey: "savedSnippets") == damaged)
    }

    private static func check(_ name: String, _ value: Bool) {
        if !value { failures += 1; print("FAIL: \(name)") }
    }
}
