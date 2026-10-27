import Foundation
import CoreGraphics

struct ScreenNote: Sendable {
    enum Kind: String, Sendable { case start, marked, switched, final }

    struct Context: Identifiable, Sendable {
        let id: UUID
        let elapsed: TimeInterval
        let appName: String
        let displayID: UInt32
        let displayName: String
    }

    struct Shot: Sendable {
        let file: URL
        let elapsed: TimeInterval
        let byteCount: Int
        let kind: Kind
        let contextID: UUID
    }

    private struct Narration {
        let contexts: [UUID]
        let files: [URL]
        let start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    static let maximumShots = 10
    static let maximumBytes = 32 * 1024 * 1024
    let id: UUID
    let directory: URL
    var contexts: [Context] = []
    var shots: [Shot] = []
    var transcript = ""
    var speech: [TranscriptSpan] = []

    func canCapture(_ kind: Kind, pending: Int = 0) -> Bool {
        let reserved = kind == .switched ? 3 : kind == .marked ? 1 : 0
        return shots.count + pending < Self.maximumShots - reserved
    }

    mutating func append(_ shot: Shot) -> Bool {
        guard contexts.contains(where: { $0.id == shot.contextID }), shots.count < Self.maximumShots,
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
        let narration = narration.map { group in
            let screens = group.contexts.compactMap { id -> String? in
                guard let context = contexts.first(where: { $0.id == id }) else { return nil }
                let files = group.files.filter { file in shots.contains { $0.contextID == id && $0.file == file } }
                let images = files.isEmpty ? "no screenshot captured" : files.map(\.lastPathComponent).joined(separator: ", ")
                return "\(context.appName) · \(context.displayName) — \(images)"
            }.joined(separator: "; ")
            return "### \(Self.time(group.start))–\(Self.time(group.end)) · \(screens)\n\n\(group.text)"
        }.joined(separator: "\n\n")
        let frames = shots.enumerated().compactMap { index, shot -> String? in
            guard let context = contexts.first(where: { $0.id == shot.contextID }) else { return nil }
            return "\(index + 1). \(shot.file.lastPathComponent) — \(Self.time(shot.elapsed))"
                + " · \(context.appName) · \(context.displayName) · \(shot.kind.rawValue)"
        }.joined(separator: "\n")
        let speech = narration.isEmpty && !transcript.isEmpty ? "Speech timing unavailable." : narration
        return "# Screen note\n\n## Narration by screen\n\n\(speech)\n\n## Full transcript\n\n\(transcript)"
            + "\n\n## Screenshots\n\n\(frames)\n"
    }

    func caption(for shot: Shot) -> String {
        guard let context = contexts.first(where: { $0.id == shot.contextID }) else { return "" }
        let groups = narration
        let nearby = groups.filter { $0.files.contains(shot.file) }.map {
            "[\(Self.time($0.start))–\(Self.time($0.end))] \($0.text)"
        }.joined(separator: "\n")
        var result = "\(shot.file.lastPathComponent) · \(Self.time(shot.elapsed)) · \(context.appName) · \(context.displayName)"
        if !nearby.isEmpty { result += "\n\nSpeech near this screenshot\n" + nearby }
        let exportedSpeech = groups.filter { !$0.files.isEmpty }.map(\.text).joined(separator: " ")
        if shot.file == shots.first?.file, !transcript.isEmpty,
           Self.normalized(exportedSpeech) != Self.normalized(transcript) {
            result += "\n\nFull session narration (includes speech without screen timing)\n" + transcript
        }
        return result
    }

    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .lowercased()
    }

    private var narration: [Narration] {
        var seen: Set<TranscriptSpan> = []
        var groups: [Narration] = []
        for span in speech.filter(\.isValid).sorted(by: { $0.start < $1.start }) where seen.insert(span).inserted {
            let selected = contexts.enumerated().filter { index, context in
                let end = index + 1 < contexts.count ? contexts[index + 1].elapsed : .infinity
                return context.elapsed <= span.start && span.start < end
                    || context.elapsed > span.start && context.elapsed < span.end
            }.map { $0.element.id }
            let midpoint = (span.start + span.end) / 2
            let files = selected.compactMap { id in
                shots.filter { $0.contextID == id }.min {
                    abs($0.elapsed - midpoint) < abs($1.elapsed - midpoint)
                }?.file
            }
            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if groups.last?.contexts == selected && groups.last?.files == files {
                groups[groups.count - 1].text += " " + text
                groups[groups.count - 1].end = max(groups[groups.count - 1].end, span.end)
            } else {
                groups.append(Narration(contexts: selected, files: files, start: span.start, end: span.end, text: text))
            }
        }
        return groups
    }

    private static func time(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
