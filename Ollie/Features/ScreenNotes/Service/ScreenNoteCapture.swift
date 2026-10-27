import AppKit
import CryptoKit
import ScreenCaptureKit

@MainActor
enum ScreenNoteCapture {
    struct Frame: Sendable {
        let image: CGImage
        let displayID: UInt32
        let pointSize: CGSize
        let displayName: String
        let appName: String
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

    static func frame(displayID: UInt32?, fallbackDisplayID: UInt32, app: NSRunningApplication?,
                      excludedWindows: [Int]) async throws -> Frame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frontWindow = windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app?.processIdentifier
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        let windowID = (frontWindow?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        let window = content.windows.first { $0.windowID == windowID }
        let contextDisplay = window.flatMap { window in
            ScreenNote.displayID(for: window.frame, displays: content.displays.map { ($0.displayID, $0.frame) })
        }
        let selected = displayID ?? contextDisplay ?? fallbackDisplayID
        guard let display = content.displays.first(where: { $0.displayID == selected }) else {
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
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selected
        }
        return Frame(image: image, displayID: selected, pointSize: size,
                     displayName: screen?.localizedName ?? "Display", appName: app?.localizedName ?? "Desktop")
    }

    nonisolated static func save(_ frame: Frame, strokes: [ScreenInk.Stroke], file: URL) throws
        -> (byteCount: Int, fingerprint: Data) {
        try Task.checkCancellation()
        guard let pixels = frame.image.dataProvider?.data else { throw Failure.imageMissing }
        let fingerprint = Data(SHA256.hash(data: pixels as Data))
        let data = try ScreenNoteImage.render(frame.image, pointSize: frame.pointSize, strokes: strokes)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (data.count, fingerprint)
    }

}
