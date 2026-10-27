import Foundation
import CoreGraphics
import ImageIO

@main
struct ScreenInkTests {
    static func main() throws {
        try compositing()
        noteLimits()
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
        let shot = ScreenNote.Shot(file: directory.appendingPathComponent("Shot 01.png"), elapsed: 65,
                                  byteCount: 10, kind: .marked, appName: "Test app", displayName: "Test display")
        for _ in 0..<(ScreenNote.maximumShots - 3) { precondition(note.append(shot)) }
        precondition(!note.canCapture(.switched) && note.canCapture(.marked) && note.canCapture(.final))
        precondition(!note.canCapture(.marked, pending: 2) && note.canCapture(.final, pending: 2))
        precondition(note.append(shot) && note.append(shot))
        precondition(!note.canCapture(.marked) && note.canCapture(.final))
        precondition(note.append(shot) && !note.append(shot) && !note.canCapture(.final))
        precondition(note.text.contains("1:05 · Test app · Test display · marked"))
        var full = ScreenNote(id: UUID(), directory: directory)
        precondition(full.append(.init(file: shot.file, elapsed: 0, byteCount: ScreenNote.maximumBytes,
                                      kind: .start, appName: "Test", displayName: "Test")))
        precondition(!full.append(shot))
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
