import Foundation

enum SnippetExpansionPolicy {
    static func shouldAutoExpand(_ exactMatch: Snippet, among matches: [Snippet]) -> Bool {
        !matches.contains { snippet in
            snippet.id != exactMatch.id && snippet.trigger.hasPrefix(exactMatch.trigger)
        }
    }

    static func draft(
        in value: String, selectedRange: NSRange, trigger: String
    ) -> (typed: String, content: String)? {
        guard selectedRange.length == 0, let caret = Range(selectedRange, in: value) else { return nil }
        let beforeCaret = value[..<caret.lowerBound]
        guard let start = beforeCaret.range(of: ">\(trigger) ", options: [.backwards, .caseInsensitive]) else {
            return nil
        }
        return (String(beforeCaret[start.lowerBound...]), String(beforeCaret[start.upperBound...]))
    }

    static func isDraftText(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    static func canStartSession(value: String?, selectedRange: NSRange?, previousCharacter: Character?) -> Bool {
        if let value, let selectedRange, let range = Range(selectedRange, in: value) {
            return value[..<range.lowerBound].last?.isWhitespace ?? true
        }
        return previousCharacter?.isWhitespace ?? true
    }

    static func appKitRect(from accessibilityRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        var rect = accessibilityRect
        rect.origin.y = primaryScreenHeight - accessibilityRect.maxY
        return rect
    }

    static func popupOrigin(
        anchor: CGRect, size: CGSize, visibleFrame: CGRect, centered: Bool, gap: CGFloat
    ) -> CGPoint {
        var x = centered ? visibleFrame.midX - size.width / 2 : anchor.minX
        var y = centered ? visibleFrame.midY - size.height / 2 : anchor.minY - size.height - gap
        if !centered, y < visibleFrame.minY { y = anchor.maxY + gap }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGPoint(x: x, y: y)
    }
}
