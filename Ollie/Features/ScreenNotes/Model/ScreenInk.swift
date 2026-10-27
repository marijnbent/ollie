import Foundation
import CoreGraphics

struct ScreenInk: Sendable {
    enum Tool: String, CaseIterable, Sendable {
        case pen, arrow

        var title: String { self == .pen ? "Pen" : "Arrow" }
        var symbol: String { self == .pen ? "pencil.tip" : "arrow.up.right" }
    }

    enum Color: String, CaseIterable, Sendable {
        case red, yellow, blue, green

        var title: String { rawValue.capitalized }

        var cgColor: CGColor {
            switch self {
            case .red: CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
            case .yellow: CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
            case .blue: CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
            case .green: CGColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            }
        }
    }

    enum Width: Int, CaseIterable, Sendable {
        case fine = 3, medium = 6, thick = 10

        var title: String {
            switch self {
            case .fine: "Fine"
            case .medium: "Medium"
            case .thick: "Thick"
            }
        }
    }

    enum Lifetime: Int, CaseIterable, Sendable {
        case manual = 0, twoSeconds = 2, fiveSeconds = 5, tenSeconds = 10

        var title: String { self == .manual ? "Until closed" : "\(rawValue) seconds" }
    }

    struct Stroke: Identifiable, Sendable {
        let id = UUID()
        let displayID: UInt32
        let tool: Tool
        let color: Color
        let width: Width
        var points: [CGPoint]
        var expiresAt: TimeInterval?

        var path: CGPath {
            let path = CGMutablePath()
            guard let first = points.first, let last = points.last else { return path }
            path.move(to: first)
            if tool == .arrow {
                path.addLine(to: last)
                let distance = hypot(last.x - first.x, last.y - first.y)
                guard distance > 0 else { return path }
                let length = min(CGFloat(width.rawValue) * 3, distance / 2)
                let angle = atan2(last.y - first.y, last.x - first.x)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: CGPoint(x: last.x - length * cos(angle + offset),
                                          y: last.y - length * sin(angle + offset)))
                    path.addLine(to: last)
                }
            } else {
                for point in points.dropFirst() { path.addLine(to: point) }
                if points.count == 1 {
                    path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
                }
            }
            return path
        }
    }

    static let maximumStrokes = 128
    static let maximumPoints = 4096
    static let fadeDuration: TimeInterval = 0.35

    private(set) var strokes: [Stroke] = []
    private(set) var active: Stroke?

    var nextExpiry: TimeInterval? { strokes.compactMap(\.expiresAt).min() }

    mutating func begin(at point: CGPoint, displayID: UInt32, tool: Tool, color: Color, width: Width) {
        active = Stroke(displayID: displayID, tool: tool, color: color, width: width, points: [point])
    }

    mutating func append(_ point: CGPoint) {
        guard let last = active?.points.last,
              hypot(point.x - last.x, point.y - last.y) >= 0.5 else { return }
        if active?.tool == .arrow {
            if active?.points.count == 1 { active?.points.append(point) } else { active?.points[1] = point }
        } else if let count = active?.points.count, count < Self.maximumPoints {
            active?.points.append(point)
        }
    }

    mutating func finish(now: TimeInterval, lifetime: Lifetime) {
        guard var stroke = active else { return }
        active = nil
        stroke.expiresAt = lifetime == .manual ? nil : now + Double(lifetime.rawValue)
        prune(now: now)
        strokes.append(stroke)
        if strokes.count > Self.maximumStrokes { strokes.removeFirst() }
    }

    mutating func prune(now: TimeInterval) {
        strokes.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
    }

    mutating func undo(now: TimeInterval) {
        prune(now: now)
        if active != nil { active = nil } else if !strokes.isEmpty { strokes.removeLast() }
    }

    mutating func clear() {
        active = nil
        strokes.removeAll()
    }

    mutating func remove(ids: Set<UUID>) {
        strokes.removeAll { ids.contains($0.id) }
        if let active, ids.contains(active.id) { self.active = nil }
    }
}
