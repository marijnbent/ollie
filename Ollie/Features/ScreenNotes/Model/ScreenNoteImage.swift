import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum ScreenNoteImage {
    enum Failure: Error { case rendering, encoding }

    static func render(_ image: CGImage, pointSize: CGSize, strokes: [ScreenInk.Stroke]) throws -> Data {
        try encode(annotate(image, pointSize: pointSize, strokes: strokes))
    }

    static func annotate(_ image: CGImage, pointSize: CGSize, strokes: [ScreenInk.Stroke]) throws -> CGImage {
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
        guard let result = context.makeImage() else { throw Failure.rendering }
        return result
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
