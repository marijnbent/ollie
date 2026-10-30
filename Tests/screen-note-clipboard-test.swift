import AppKit
import ImageIO
import Vision

@main
@MainActor
struct ScreenNoteClipboardTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var note = ScreenNote(id: UUID(), directory: directory)
        note.transcript = "The save button is clipped. The filter is missing."
        note.speech = [TranscriptSpan(text: "The save button is clipped.", start: 1, end: 2),
                       TranscriptSpan(text: "The filter is missing.", start: 7, end: 8)]
        for index in 0..<2 {
            let context = ScreenNote.Context(id: UUID(), elapsed: Double(index * 5), appName: "Test app",
                                             displayID: UInt32(index + 1), displayName: "Display \(index + 1)")
            note.contexts.append(context)
            let file = directory.appendingPathComponent("Shot \(index + 1).png")
            let bitmap = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(CGColor(gray: 0.9, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            let bytes = try ScreenNoteImage.render(bitmap.makeImage()!, pointSize: CGSize(width: 1280, height: 720), strokes: [])
            try bytes.write(to: file)
            precondition(note.append(.init(file: file, elapsed: Double(index * 5), byteCount: bytes.count,
                                          kind: index == 0 ? .start : .marked, contextID: context.id)))
        }
        let payload = try await Task.detached { [note] in try ScreenNoteClipboard.prepare(note) }.value
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(ScreenNoteClipboard.write(payload, to: pasteboard))
        precondition(pasteboard.string(forType: .string) == note.text)
        let files = PasteboardFiles.urls(on: pasteboard)
        precondition(files == note.shots.map(\.file) + [directory.appendingPathComponent("Note.md")])
        let noteText = try String(contentsOf: files.last!, encoding: .utf8)
        precondition(noteText == note.text)
        let images = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: .png) }
        precondition(images.count == 2 && pasteboard.pasteboardItems?.count == 4)
        for (index, data) in images.enumerated() {
            let stored = try Data(contentsOf: files[index])
            precondition(data == stored)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            precondition(image.width == 1280 && image.height > 720)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            precondition(text.contains(index == 0 ? "save button is clipped" : "filter is missing"))
            precondition(!text.contains(index == 0 ? "filter is missing" : "save button is clipped"))
        }
        print("Private clipboard PNGs contain the matching spoken words, alongside text and the note file")
    }
}
