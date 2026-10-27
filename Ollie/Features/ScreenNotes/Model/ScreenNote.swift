import Foundation

struct ScreenNote: Sendable {
    struct Shot: Sendable {
        let file: URL
        let elapsed: TimeInterval
        let byteCount: Int
    }

    static let maximumShots = 10
    static let maximumBytes = 32 * 1024 * 1024
    let id: UUID
    let directory: URL
    let displayName: String
    var shots: [Shot] = []
    var transcript = ""

    var canAddShot: Bool { shots.count < Self.maximumShots }

    mutating func append(_ shot: Shot) -> Bool {
        guard canAddShot, shots.reduce(0, { $0 + $1.byteCount }) + shot.byteCount <= Self.maximumBytes else { return false }
        shots.append(shot)
        return true
    }

    var text: String {
        let frames = shots.enumerated().map { index, shot in
            let seconds = max(0, Int(shot.elapsed))
            return "\(index + 1). \(shot.file.lastPathComponent) (\(seconds / 60):\(String(format: "%02d", seconds % 60)))"
        }.joined(separator: "\n")
        return "# Screen note — \(displayName)\n\n\(transcript)\n\n## Screenshots\n\n\(frames)\n"
    }
}
