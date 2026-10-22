import AppKit
import Foundation

@main
@MainActor
struct ClipboardCoordinatorTests {
    private static var failures = 0

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        AppPaths.directory = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsName = "ollie.coordinator-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let core = AppCore()
        let coordinator = ClipboardCoordinator(core: core, ticker: HealthTicker(), snippets: SnippetStore(defaults: defaults))
        coordinator.watcher.pause()
        await coordinator.store.load()
        let alpha = ClipboardItem.text("alpha needle", timestamp: Date())
        let beta = ClipboardItem.text("beta needle", timestamp: Date())
        let gamma = ClipboardItem.text("gamma needle", timestamp: Date())
        coordinator.store.add(gamma)
        coordinator.store.add(beta)
        coordinator.store.add(alpha)
        core.palette.query = "needle"
        coordinator.refreshSearch()
        await settleSearch(coordinator)
        let initial = coordinator.results(for: "needle")
        check("search fixture has three matches", initial.count == 3)
        core.palette.selection = 0
        coordinator.refreshSearch()
        core.palette.selection = 2
        let chosen = coordinator.results(for: "needle")[2].id
        await settleSearch(coordinator)
        check("refresh preserves navigation made while searching", selectedID(coordinator, core: core) == chosen)

        core.palette.selection = 1
        let survivor = coordinator.results(for: "needle")[1].id
        coordinator.store.delete(alpha)
        coordinator.refreshSearch()
        check("deletion immediately preserves the surviving selection", selectedID(coordinator, core: core) == survivor)
        await settleSearch(coordinator)
        check("deletion refresh keeps the surviving selection", selectedID(coordinator, core: core) == survivor)

        PasteController.copied = []
        core.settings.clipboardEnabled = true
        coordinator.activate(.item(beta), copyOnly: true)
        core.settings.clipboardEnabled = false
        coordinator.apply()
        try await Task.sleep(for: .milliseconds(30))
        check("disabled history cancels queued copies", PasteController.copied.isEmpty)
        check("disabled history switches the open panel to snippets", core.palette.query == ">")
        check("disabling history leaves snippets running", coordinator.snippetsRunning)

        try coordinator.snippets.saveSnippet(title: "", trigger: "fixture", content: "snippet text")
        let snippet = coordinator.snippets.snippets[0]
        check("greater-than searches snippets", coordinator.results(for: ">fixture").map(\.id) == ["snippet-\(snippet.id)"])
        check("colon no longer searches snippets", coordinator.results(for: ":fixture").isEmpty)
        core.settings.clipboardEnabled = true
        coordinator.activate(.snippet(snippet), copyOnly: true)
        core.settings.clipboardEnabled = false
        coordinator.apply()
        try await Task.sleep(for: .milliseconds(30))
        check("disabling history preserves a snippet copy", PasteController.copied == [.text("snippet text")])

        PasteController.copied = []
        coordinator.activate(.snippet(snippet), copyOnly: true)
        core.settings.snippetsEnabled = false
        coordinator.apply()
        try await Task.sleep(for: .milliseconds(30))
        check("disabled snippets cancel queued copies", PasteController.copied.isEmpty)
        check("disabling both features closes the panel", !core.paletteCoordinator.isVisible)

        core.settings.clipboardEnabled = true
        core.settings.snippetsEnabled = true
        coordinator.editSnippet(.item(beta))
        core.settings.snippetsEnabled = false
        coordinator.apply()
        try await Task.sleep(for: .milliseconds(30))
        check("disabling snippets cancels a queued editor", coordinator.snippetEditor == nil)
        check("cancelled editor does not open Settings", core.settingsCoordinator.opened.isEmpty)

        core.settings.clipboardEnabled = true
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let filename = coordinator.store.storage.saveImage(image.tiffRepresentation!)!
        let item = ClipboardItem.image(filename: filename, timestamp: Date())
        coordinator.store.add(item)
        OCRService.handler = { _ in
            core.settings.clipboardEnabled = false
            coordinator.apply()
            return "late OCR result"
        }
        coordinator.runOCR(item)
        for _ in 0..<100 where coordinator.extractingItemID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        check("disabled OCR does not update history", coordinator.store.items.first { $0.id == item.id }?.ocrText == nil)
        check("disabled OCR does not copy", PasteController.copied.isEmpty)
        check("disabled OCR does not show a completion popup", core.messages.isEmpty)
        check("cancelled OCR releases its busy state", coordinator.extractingItemID == nil)
        OCRService.handler = { _ in "fresh OCR result" }
        core.settings.clipboardEnabled = true
        coordinator.runOCR(item)
        for _ in 0..<100 where coordinator.extractingItemID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        check("OCR works again after re-enabling", PasteController.copied == [.text("fresh OCR result")])
        coordinator.stop()
        _ = await coordinator.store.flush()
        print(failures == 0 ? "Clipboard coordinator passed" : "\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func settleSearch(_ coordinator: ClipboardCoordinator) async {
        for _ in 0..<200 where coordinator.searchSession.isSearching {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func selectedID(_ coordinator: ClipboardCoordinator, core: AppCore) -> String? {
        let rows = coordinator.results(for: core.palette.query)
        return rows.indices.contains(core.palette.selection) ? rows[core.palette.selection].id : nil
    }

    private static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1; print("FAIL: \(name)") }
    }
}

@MainActor final class AppCore {
    let textInjector = TestTextInjector()
    let settings = TestSettings()
    let appIndex = TestAppIndex()
    let palette = TestPalette()
    lazy var paletteCoordinator = TestPaletteCoordinator(palette: palette)
    let settingsCoordinator = TestSettingsCoordinator()
    var messages: [String] = []
    func showMessage(_ message: String, tone: DialogTone = .success) { messages.append(message) }
    func confirm(title: String, message: String?, symbol: String?, confirmTitle: String) async -> Bool { false }
}

@MainActor final class TestSettings {
    var clipboardEnabled = true
    var snippetsEnabled = true
    var clipboardHistoryDays = 7
}

enum CommandID { case clipboardHistory }
@MainActor final class TestAppIndex {
    func setCommandsVisible(_ commands: [CommandID], _ visible: Bool) {}
}

enum PaletteMode { case clipboard, launcher }
@MainActor final class TestPalette {
    var mode: PaletteMode = .clipboard
    var query = ""
    var selection = 0
}

@MainActor final class TestPaletteCoordinator {
    let palette: TestPalette
    var isVisible = true
    var targetApp: NSRunningApplication?
    init(palette: TestPalette) { self.palette = palette }
    func isShowing(_ mode: PaletteMode) -> Bool { isVisible && palette.mode == mode }
    func hidePalette() { isVisible = false }
    func showPalette(mode: PaletteMode, seeding: String) {
        isVisible = true
        palette.mode = mode
        palette.query = seeding
    }
}

enum SettingsTab { case snippets }
@MainActor final class TestSettingsCoordinator {
    var opened: [SettingsTab] = []
    func showSettings(tab: SettingsTab) { opened.append(tab) }
}

enum DialogTone { case success, danger, neutral }
@MainActor enum Permissions { static func ensureAccessibility() -> Bool { true } }
@MainActor enum AppPaths {
    static var directory = FileManager.default.temporaryDirectory
    static func applicationSupport() -> URL { directory }
}

@MainActor protocol HealthCheckable: AnyObject { func healthCheck() }
@MainActor final class HealthTicker {
    func subscribe(_ subscriber: any HealthCheckable) {}
    func unsubscribe(_ subscriber: any HealthCheckable) {}
}

@MainActor final class SnippetExpansionController {
    var isRunning = false
    init(store: SnippetStore, injector: TestTextInjector) {}
    func stop() { isRunning = false }
    func start() { isRunning = true }
}

@MainActor final class TestTextInjector {}

struct SnippetEditorTarget {
    let snippet: Snippet?
    var content = ""
}

enum ClipboardContentError: Error { case unavailable }
enum PreparedClipboardContent: Sendable, Equatable {
    case text(String)
    case image(png: Data, tiff: Data)
}

@MainActor enum PasteController {
    static var copied: [PreparedClipboardContent] = []
    static func copyToClipboard(_ content: PreparedClipboardContent) -> Bool { copied.append(content); return true }
    static func copyTextToClipboard(_ text: String) -> Bool { copyToClipboard(.text(text)) }
    static func paste(_ content: PreparedClipboardContent, targetApplication: NSRunningApplication?) async -> Bool {
        copyToClipboard(content)
    }
}

@MainActor enum OCRService {
    static var handler: (NSImage) async -> String? = { _ in nil }
    static func recognizeText(from image: NSImage) async -> String? { await handler(image) }
}

extension Notification.Name {
    static let bufferDidWritePasteboard = Notification.Name("bufferDidWritePasteboard")
}
