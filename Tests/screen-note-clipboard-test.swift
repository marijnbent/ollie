import AppKit

@main
@MainActor
struct ScreenNoteClipboardTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var note = ScreenNote(id: UUID(), directory: directory)
        note.transcript = "The save button is clipped."
        for index in 1...2 {
            let file = directory.appendingPathComponent("Shot \(index).png")
            let bytes = Data([UInt8(index)])
            try bytes.write(to: file)
            precondition(note.append(.init(file: file, elapsed: Double(index), byteCount: bytes.count,
                                          kind: index == 1 ? .start : .marked,
                                          appName: "Test app", displayName: "Test display")))
        }
        let payload = try await Task.detached { [note] in try ScreenNoteClipboard.prepare(note) }.value
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(ScreenNoteClipboard.write(payload, to: pasteboard))
        precondition(pasteboard.string(forType: .string) == note.text)
        let files = PasteboardFiles.urls(on: pasteboard)
        precondition(files == note.shots.map(\.file) + [directory.appendingPathComponent("Note.md")])
        let storedText = try String(contentsOf: files.last!, encoding: .utf8)
        precondition(storedText == note.text && storedText.contains("Test app · Test display · marked"))
        let images = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: .png) }
        precondition(images == [Data([1]), Data([2])])
        precondition(pasteboard.pasteboardItems?.count == 4)
        print("Private clipboard preserves transcript, separate PNGs and the note file")
    }
}
