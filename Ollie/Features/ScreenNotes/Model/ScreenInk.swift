import Foundation
import CoreGraphics

struct ScreenInk: Sendable {
    struct Stroke: Identifiable, Sendable {
        let id = UUID()
        let displayID: UInt32
        var points: [CGPoint]

        var path: CGPath {
            let path = CGMutablePath()
            guard let first = points.first else { return path }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            return path
        }
    }

    struct Sample: Sendable {
        let point: CGPoint
        let displayID: UInt32
        let elapsed: TimeInterval
    }

    static let maximumPoints = 4096
    static let color = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let width: CGFloat = 3
    private(set) var samples: [Sample] = []

    mutating func record(_ point: CGPoint, displayID: UInt32, elapsed: TimeInterval) {
        guard elapsed.isFinite, point.x.isFinite, point.y.isFinite else { return }
        if let last = samples.last {
            guard elapsed >= last.elapsed else { return }
            if last.displayID == displayID,
               hypot(point.x - last.point.x, point.y - last.point.y) < 2 { return }
        }
        if samples.count >= Self.maximumPoints {
            samples = samples.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        }
        samples.append(Sample(point: point, displayID: displayID, elapsed: elapsed))
    }

    func strokes(displayID: UInt32, ranges: [ClosedRange<TimeInterval>]) -> [Stroke] {
        var result: [Stroke] = []
        for range in ranges {
            var points: [CGPoint] = []
            for sample in samples {
                if sample.displayID == displayID && range.contains(sample.elapsed) {
                    points.append(sample.point)
                } else if !points.isEmpty {
                    result.append(Stroke(displayID: displayID, points: points))
                    points = []
                }
            }
            if !points.isEmpty { result.append(Stroke(displayID: displayID, points: points)) }
        }
        return result
    }
}
