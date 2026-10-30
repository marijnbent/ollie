import AppKit
import CryptoKit
import ScreenCaptureKit

@MainActor
enum ScreenNoteCapture {
    struct Frame: Sendable {
        let image: CGImage
        let displayID: UInt32
        let pointSize: CGSize
    }

    enum Failure: LocalizedError {
        case displayMissing, imageMissing

        var errorDescription: String? {
            switch self {
            case .displayMissing: "The display is no longer connected."
            case .imageMissing: "macOS did not return a screenshot."
            }
        }
    }

    static func context(elapsed: TimeInterval, displayID: UInt32? = nil) -> ScreenNote.Context? {
        let app = NSWorkspace.shared.frontmostApplication
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frontWindow = windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app?.processIdentifier
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        let bounds = (frontWindow?[kCGWindowBounds as String] as? [String: Any]).flatMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        }
        let displays = NSScreen.screens.compactMap { screen -> (id: UInt32, frame: CGRect)? in
            guard let id = screenID(screen) else { return nil }
            return (id, CGDisplayBounds(id))
        }
        let focused = bounds.flatMap { ScreenNote.displayID(for: $0, displays: displays) }
        guard let selected = displayID ?? focused ?? NSScreen.underCursor.flatMap(screenID),
              let screen = NSScreen.screens.first(where: { screenID($0) == selected }) else { return nil }
        return ScreenNote.Context(id: UUID(), elapsed: elapsed, appName: app?.localizedName ?? "Desktop",
                                  displayID: selected, displayName: screen.localizedName)
    }

    static func frame(displayID: UInt32, excludedWindows: [Int]) async throws -> Frame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayMissing
        }
        let excluded = content.windows.filter { excludedWindows.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let size = display.frame.size
        let scale = min(2, 2560 / max(size.width, size.height))
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw Failure.imageMissing }
        return Frame(image: image, displayID: displayID, pointSize: size)
    }

    nonisolated static func save(_ frame: Frame, file: URL) throws
        -> (byteCount: Int, fingerprint: Data) {
        try Task.checkCancellation()
        guard let pixels = frame.image.dataProvider?.data else { throw Failure.imageMissing }
        let fingerprint = Data(SHA256.hash(data: pixels as Data))
        let data = try ScreenNoteImage.render(frame.image, pointSize: frame.pointSize, strokes: [])
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (data.count, fingerprint)
    }

    static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
