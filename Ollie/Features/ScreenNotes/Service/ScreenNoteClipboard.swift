import AppKit

enum ScreenNoteClipboard {
    struct Payload: Sendable {
        let text: String
        let files: [(url: URL, png: Data?)]
    }

    nonisolated static func prepare(_ note: ScreenNote) throws -> Payload {
        let noteFile = note.directory.appendingPathComponent("Note.md")
        try Data(note.text.utf8).write(to: noteFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noteFile.path)
        var files = try note.shots.map { (url: $0.file, png: Optional(try Data(contentsOf: $0.file))) }
        files.append((url: noteFile, png: nil))
        return Payload(text: note.text, files: files)
    }

    @MainActor
    static func write(_ payload: Payload, to pasteboard: NSPasteboard) -> Bool {
        let text = NSPasteboardItem()
        text.setString(payload.text, forType: .string)
        let files = payload.files.map { file in
            let item = NSPasteboardItem()
            item.setData(file.url.dataRepresentation, forType: .fileURL)
            if let png = file.png { item.setData(png, forType: .png) }
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([text] + files)
    }
}
