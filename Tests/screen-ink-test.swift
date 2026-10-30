import Foundation
import CoreGraphics
import ImageIO

@main
struct ScreenInkTests {
    static func main() throws {
        try compositing()
        noteLimits()
        speechContexts()
        let displays: [(id: UInt32, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CGRect(x: -100, y: 0, width: 100, height: 100))
        ]
        precondition(ScreenNote.displayID(for: CGRect(x: -70, y: 10, width: 90, height: 50), displays: displays) == 2)
        precondition(ScreenNote.displayID(for: CGRect(x: -20, y: 10, width: 90, height: 50), displays: displays) == 1)
        precondition(ScreenNote.displayID(for: CGRect(x: 200, y: 0, width: 50, height: 50), displays: displays) == nil)
        var ink = ScreenInk()
        ink.begin(at: .zero, displayID: 2)
        ink.append(CGPoint(x: 0.1, y: 0.1))
        precondition(ink.active?.points.count == 1)
        for index in 1..<(ScreenInk.maximumPoints * 2) { ink.append(CGPoint(x: index, y: 0)) }
        precondition(ink.active?.points.count == ScreenInk.maximumPoints)
        let stroke = ink.finish()!
        precondition(stroke.displayID == 2 && ink.active == nil && ink.finish() == nil)
        precondition(stroke.path.boundingBoxOfPath.width == CGFloat(ScreenInk.maximumPoints - 1))
        ink.begin(at: .zero, displayID: 1)
        precondition(ink.active!.path.boundingBoxOfPath.width > 0)
        print("Screen marker geometry, storage bounds and reserved capture slots passed")
    }

    static func noteLimits() {
        let directory = URL(fileURLWithPath: "/unused")
        var note = ScreenNote(id: UUID(), directory: directory)
        let context = ScreenNote.Context(id: UUID(), elapsed: 0, appName: "Test app", displayID: 1, displayName: "Test display")
        note.contexts = [context]
        let shot = ScreenNote.Shot(file: directory.appendingPathComponent("Shot 01.png"), elapsed: 65,
                                  byteCount: 10, kind: .marked, contextID: context.id)
        for _ in 0..<(ScreenNote.maximumShots - 3) { precondition(note.append(shot)) }
        precondition(!note.canCapture(.switched) && note.canCapture(.marked) && note.canCapture(.final))
        precondition(!note.canCapture(.marked, pending: 2) && note.canCapture(.final, pending: 2))
        precondition(note.append(shot) && note.append(shot))
        precondition(!note.canCapture(.marked) && note.canCapture(.final))
        precondition(note.append(shot) && !note.append(shot) && !note.canCapture(.final))
        precondition(note.text.contains("1:05 · Test app · Test display · marked"))
        var full = ScreenNote(id: UUID(), directory: directory)
        full.contexts = [context]
        precondition(full.append(.init(file: shot.file, elapsed: 0, byteCount: ScreenNote.maximumBytes,
                                      kind: .start, contextID: context.id)))
        precondition(!full.append(shot))
    }

    static func speechContexts() {
        var note = ScreenNote(id: UUID(), directory: URL(filePath: "/unused"))
        let first = ScreenNote.Context(id: UUID(), elapsed: 0, appName: "Safari", displayID: 1, displayName: "Left")
        let second = ScreenNote.Context(id: UUID(), elapsed: 10, appName: "Editor", displayID: 2, displayName: "Right")
        let returned = ScreenNote.Context(id: UUID(), elapsed: 20, appName: "Safari", displayID: 1, displayName: "Left")
        note.contexts = [first, second, returned]
        for (index, context, elapsed) in [(1, first, 0.0), (2, first, 5.0), (3, second, 10.5), (4, returned, 20.0)] {
            precondition(note.append(.init(file: note.directory.appendingPathComponent("Shot \(index).png"), elapsed: elapsed,
                                          byteCount: 10, kind: .marked, contextID: context.id)))
        }
        let early = TranscriptSpan(text: "Make this red.", start: 4, end: 5)
        note.speech = [TranscriptSpan(text: "Change the filter.", start: 10.1, end: 12),
                       TranscriptSpan(text: "Now make it blue.", start: 21, end: 23), early, early]
        note.transcript = "Make this red. Change the filter. Now make it blue."
        precondition(note.caption(for: note.shots[1]).contains("Make this red."))
        precondition(!note.caption(for: note.shots[1]).contains("Change the filter."))
        precondition(note.caption(for: note.shots[2]).contains("Change the filter."))
        precondition(!note.caption(for: note.shots[3]).contains("Make this red."))
        precondition(note.caption(for: note.shots[3]).contains("Now make it blue."))
        precondition(note.text.components(separatedBy: "Make this red.").count == 3)
        note.speech = []
        precondition(note.caption(for: note.shots[0]).contains(note.transcript))
        precondition(note.text.contains("Speech timing unavailable."))
    }

    static func compositing() throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                      bytesPerRow: 800, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { preconditionFailure("No synthetic bitmap") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 140, width: 60, height: 40))
        let background = context.data!.assumingMemoryBound(to: UInt8.self)
        let blackRows = Set((0..<200).filter { background[$0 * 800 + 50 * 4] < 10 })
        let original = context.makeImage()!
        let stroke = ScreenInk.Stroke(displayID: 1,
                                     points: [CGPoint(x: 10, y: 80), CGPoint(x: 40, y: 80)])
        let png = try ScreenNoteImage.render(original, pointSize: CGSize(width: 100, height: 100), strokes: [stroke])
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let rendered = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(rendered.width == 200 && rendered.height == 200)
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let redRows = (0..<200).filter { row in
            let offset = row * 800 + 50 * 4
            return pixels[offset] > 230 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100
        }
        precondition(!redRows.isEmpty && redRows.allSatisfy { blackRows.contains($0) })
        let unchanged = 100 * 800 + 50 * 4
        precondition(pixels[unchanged] > 230 && pixels[unchanged + 1] > 230)
    }
}
