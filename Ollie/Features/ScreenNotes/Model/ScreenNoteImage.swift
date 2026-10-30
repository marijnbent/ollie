import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum ScreenNoteImage {
    enum Failure: Error { case rendering, encoding }

    static func render(_ image: CGImage, pointSize: CGSize, strokes: [ScreenInk.Stroke]) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.rendering }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: CGFloat(image.width) / pointSize.width, y: CGFloat(image.height) / pointSize.height)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setStrokeColor(ScreenInk.color)
            context.setLineWidth(ScreenInk.width)
            context.addPath(stroke.path)
            context.strokePath()
        }
        if strokes.count > 1 {
            for (index, stroke) in strokes.enumerated() {
                guard let start = stroke.points.first else { continue }
                badge(index + 1, at: start, in: context)
            }
        }
        guard let result = context.makeImage() else { throw Failure.rendering }
        return try encode(result)
    }

    static func looksSame(_ first: CGImage, _ second: CGImage) -> Bool {
        guard first.width == second.width, first.height == second.height,
              let a = thumbnail(first), let b = thumbnail(second) else { return false }
        return zip(a, b).filter { abs(Int($0) - Int($1)) > 32 }.count <= 3
    }

    private static func thumbnail(_ image: CGImage) -> [UInt8]? {
        let width = 128
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    private static func badge(_ number: Int, at point: CGPoint, in context: CGContext) {
        let radius: CGFloat = 10
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(ScreenInk.color)
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: circle)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        CTLineDraw(line, context)
    }

    static func caption(_ image: CGImage, text: String, font: CTFont) throws -> Data {
        let padding = CTFontGetSize(font)
        let width = CGFloat(image.width)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: max(1, width - padding * 2), height: .greatestFiniteMagnitude), nil)
        let footer = ceil(size.height + padding * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height + Int(footer),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.rendering }
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        context.draw(image, in: CGRect(x: 0, y: footer, width: width, height: CGFloat(image.height)))
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: max(1, width - padding * 2),
                                      height: footer - padding * 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let result = context.makeImage() else { throw Failure.rendering }
        return try encode(result)
    }

    private static func encode(_ result: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }
}
