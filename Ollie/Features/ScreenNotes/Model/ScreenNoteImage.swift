import Foundation
import CoreGraphics
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
            context.setStrokeColor(stroke.color.cgColor)
            context.setLineWidth(CGFloat(stroke.width.rawValue))
            context.addPath(stroke.path)
            context.strokePath()
        }
        guard let result = context.makeImage() else { throw Failure.rendering }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }
}
