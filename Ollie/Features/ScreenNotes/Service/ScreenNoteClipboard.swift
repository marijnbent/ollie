import AppKit
import CoreText
import ImageIO

enum ScreenNoteClipboard {
    struct Payload: Sendable {
        let text: String
        let files: [(url: URL, png: Data?)]
    }

    nonisolated static func prepare(_ note: ScreenNote) throws -> Payload {
        let noteFile = note.directory.appendingPathComponent("Note.md")
        try Data(note.text.utf8).write(to: noteFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noteFile.path)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        var totalBytes = 0
        var files = try note.shots.map { shot -> (url: URL, png: Data?) in
            guard let source = CGImageSourceCreateWithURL(shot.file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenNoteImage.Failure.rendering }
            let data = try ScreenNoteImage.caption(image, text: note.caption(for: shot), font: font)
            totalBytes += data.count
            guard totalBytes <= ScreenNote.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: shot.file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shot.file.path)
            return (url: shot.file, png: data)
        }
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
