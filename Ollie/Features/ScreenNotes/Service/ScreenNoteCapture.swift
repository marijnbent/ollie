import AppKit
import ScreenCaptureKit

@MainActor
enum ScreenNoteCapture {
    enum Failure: LocalizedError {
        case displayMissing, imageMissing

        var errorDescription: String? {
            switch self {
            case .displayMissing: "The selected display is no longer connected."
            case .imageMissing: "macOS did not return a screenshot."
            }
        }
    }

    static func capture(displayID: UInt32, pointSize: CGSize, excludedWindows: [Int],
                        strokes: [ScreenInk.Stroke], file: URL) async throws -> Int {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayMissing
        }
        let excluded = content.windows.filter { excludedWindows.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = min(2, 2560 / max(pointSize.width, pointSize.height))
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int((pointSize.width * scale).rounded()))
        configuration.height = max(1, Int((pointSize.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw Failure.imageMissing }
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try ScreenNoteImage.render(image, pointSize: pointSize, strokes: strokes)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return data.count
        }.value
    }
}
