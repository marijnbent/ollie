import Foundation
import CoreGraphics
import ImageIO

@main
struct ScreenInkTests {
    static func main() throws {
        try compositing()
        noteLimits()
        var ink = ScreenInk()
        func begin(_ displayID: UInt32 = 1, tool: ScreenInk.Tool = .pen) {
            ink.begin(at: .zero, displayID: displayID, tool: tool, color: .red, width: .medium)
        }

        begin()
        ink.append(CGPoint(x: 0.1, y: 0.1))
        precondition(ink.active?.points.count == 1)
        ink.append(CGPoint(x: 10, y: 10))
        ink.finish(now: 10, lifetime: .fiveSeconds)
        precondition(ink.nextExpiry == 15)
        ink.prune(now: 14.9)
        precondition(ink.strokes.count == 1)
        ink.prune(now: 15)
        precondition(ink.strokes.isEmpty && ink.nextExpiry == nil)

        begin(tool: .arrow)
        for index in 1...100 { ink.append(CGPoint(x: index, y: 0)) }
        precondition(ink.active?.points.count == 2)
        let arrowBounds = ink.active!.path.boundingBoxOfPath
        precondition(abs(arrowBounds.minY + 9) < 0.001)
        precondition(abs(arrowBounds.width - 100) < 0.001 && abs(arrowBounds.height - 18) < 0.001)
        ink.finish(now: 20, lifetime: .manual)
        precondition(ink.strokes.count == 1 && ink.nextExpiry == nil)
        let captured = ink.strokes[0].id
        begin(2)
        ink.remove(ids: [captured])
        precondition(ink.strokes.isEmpty && ink.active?.displayID == 2)
        ink.clear()
        begin(tool: .arrow)
        ink.finish(now: 20, lifetime: .manual)
        ink.prune(now: 1_000)
        precondition(ink.strokes.count == 1)

        begin(2)
        ink.finish(now: 21, lifetime: .twoSeconds)
        precondition(ink.strokes.map(\.displayID) == [1, 2])
        ink.undo(now: 24)
        precondition(ink.strokes.isEmpty)
        begin()
        ink.undo(now: 25)
        precondition(ink.active == nil)

        begin()
        for index in 0..<(ScreenInk.maximumPoints * 2) {
            ink.append(CGPoint(x: index, y: 0))
        }
        precondition(ink.active?.points.count == ScreenInk.maximumPoints)
        ink.finish(now: 30, lifetime: .manual)
        let oldestID = ink.strokes[0].id
        for _ in 0..<ScreenInk.maximumStrokes {
            begin()
            ink.finish(now: 30, lifetime: .manual)
        }
        precondition(ink.strokes.count == ScreenInk.maximumStrokes)
        precondition(!ink.strokes.contains { $0.id == oldestID })
        ink.clear()
        precondition(ink.strokes.isEmpty && ink.active == nil && ink.nextExpiry == nil)

        begin(tool: .arrow)
        precondition(ink.active?.path.boundingBoxOfPath.origin == .zero)
        ink.append(CGPoint(x: 1, y: 0))
        precondition((ink.active?.path.boundingBoxOfPath.width ?? 0) <= 1)
        print("Screen ink expiry, global undo, geometry and storage bounds passed")
    }

    static func noteLimits() {
        let directory = URL(fileURLWithPath: "/unused")
        var note = ScreenNote(id: UUID(), directory: directory, displayName: "Test display")
        let shot = ScreenNote.Shot(file: directory.appendingPathComponent("Shot 01.png"), elapsed: 65, byteCount: 10)
        for _ in 0..<ScreenNote.maximumShots { precondition(note.append(shot)) }
        precondition(!note.append(shot) && !note.canAddShot)
        precondition(note.text.contains("(1:05)") && note.text.contains("Test display"))
        var full = ScreenNote(id: UUID(), directory: directory, displayName: "Test")
        precondition(full.append(.init(file: shot.file, elapsed: 0, byteCount: ScreenNote.maximumBytes)))
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
        let stroke = ScreenInk.Stroke(displayID: 1, tool: .pen, color: .yellow, width: .fine,
                                     points: [CGPoint(x: 10, y: 80), CGPoint(x: 40, y: 80)])
        let png = try ScreenNoteImage.render(original, pointSize: CGSize(width: 100, height: 100), strokes: [stroke])
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let rendered = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(rendered.width == 200 && rendered.height == 200)
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let yellowRows = (0..<200).filter { row in
            let offset = row * 800 + 50 * 4
            return pixels[offset] > 230 && pixels[offset + 1] > 150 && pixels[offset + 2] < 40
        }
        precondition(!yellowRows.isEmpty && yellowRows.allSatisfy { blackRows.contains($0) })
        let unchanged = 100 * 800 + 50 * 4
        precondition(pixels[unchanged] > 230 && pixels[unchanged + 1] > 230)
    }
}
