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

    static let maximumPoints = 4096
    static let color = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let width: CGFloat = 6
    private(set) var active: Stroke?

    mutating func begin(at point: CGPoint, displayID: UInt32) {
        active = Stroke(displayID: displayID, points: [point])
    }

    mutating func append(_ point: CGPoint) {
        guard let active, let last = active.points.last, active.points.count < Self.maximumPoints,
              hypot(point.x - last.x, point.y - last.y) >= 0.5 else { return }
        self.active?.points.append(point)
    }

    mutating func finish() -> Stroke? {
        defer { active = nil }
        return active
    }
}
