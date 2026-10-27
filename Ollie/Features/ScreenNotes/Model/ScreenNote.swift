import Foundation
import CoreGraphics

struct ScreenNote: Sendable {
    enum Kind: String, Sendable { case start, marked, switched, final }

    struct Shot: Sendable {
        let file: URL
        let elapsed: TimeInterval
        let byteCount: Int
        let kind: Kind
        let appName: String
        let displayName: String
    }

    static let maximumShots = 10
    static let maximumBytes = 32 * 1024 * 1024
    let id: UUID
    let directory: URL
    var shots: [Shot] = []
    var transcript = ""

    func canCapture(_ kind: Kind, pending: Int = 0) -> Bool {
        let reserved = kind == .switched ? 3 : kind == .marked ? 1 : 0
        return shots.count + pending < Self.maximumShots - reserved
    }

    mutating func append(_ shot: Shot) -> Bool {
        guard shots.count < Self.maximumShots,
              shots.reduce(0, { $0 + $1.byteCount }) + shot.byteCount <= Self.maximumBytes else { return false }
        shots.append(shot)
        return true
    }

    static func displayID(for window: CGRect, displays: [(id: UInt32, frame: CGRect)]) -> UInt32? {
        let areas = displays.map { display in
            let intersection = display.frame.intersection(window)
            return (id: display.id, area: intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        guard let largest = areas.max(by: { $0.area < $1.area }), largest.area > 0 else { return nil }
        return largest.id
    }

    var text: String {
        let frames = shots.enumerated().map { index, shot in
            let seconds = max(0, Int(shot.elapsed))
            let time = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
            return "\(index + 1). \(shot.file.lastPathComponent) — \(time) · \(shot.appName)"
                + " · \(shot.displayName) · \(shot.kind.rawValue)"
        }.joined(separator: "\n")
        return "# Screen note\n\n\(transcript)\n\n## Screenshots\n\n\(frames)\n"
    }
}
