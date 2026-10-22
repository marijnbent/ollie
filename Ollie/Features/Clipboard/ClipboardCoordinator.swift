import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardCoordinator: HealthCheckable {
    let store: ClipboardStore
    let snippets: SnippetStore
    let watcher: ClipboardWatcher
    private unowned let core: AppCore
    private let ticker: HealthTicker
    @ObservationIgnored private lazy var expansion = SnippetExpansionController(store: snippets, injector: core.textInjector)
    let searchSession = ClipboardSearchSession()
    var expandedImage: ClipboardItem?
    var snippetEditor: SnippetEditorTarget?
    private(set) var extractingItemID: UUID?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActivation: String?
    @ObservationIgnored private var snippetQuery: String?
    @ObservationIgnored private var snippetResults: [ClipboardResult] = []
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var contentOperation: ContentOperation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private(set) var snippetsRunning = false
    var isCapturingShortcut = false { didSet { applyExpansion() } }
    var isRecording = false { didSet { applyExpansion() } }

    init(core: AppCore, ticker: HealthTicker, snippets: SnippetStore = SnippetStore()) {
        self.core = core
        self.ticker = ticker
        self.snippets = snippets
        store = ClipboardStore(storageDirectory: AppPaths.applicationSupport().appendingPathComponent("Clipboard"))
        watcher = ClipboardWatcher(store: store)
    }

    func apply() {
        core.appIndex.setCommandsVisible([.clipboardHistory], core.settings.clipboardEnabled || core.settings.snippetsEnabled)
        store.historyLimit = ClipboardHistoryLimit(rawValue: core.settings.clipboardHistoryDays) ?? .defaultValue
        applyExpansion()
        if let contentOperation, !isEnabled(contentOperation) { contentTask?.cancel() }
        if !core.settings.clipboardEnabled {
            ocrTask?.cancel()
            expandedImage = nil
        }
        if !core.settings.snippetsEnabled { snippetEditor = nil }
        if !core.settings.clipboardEnabled && !core.settings.snippetsEnabled {
            pendingActivation = nil
            searchSession.cancel()
            if core.paletteCoordinator.isShowing(.clipboard) { core.paletteCoordinator.hidePalette() }
        } else if core.paletteCoordinator.isShowing(.clipboard) {
            let showingSnippets = core.palette.query.hasPrefix(">")
            if (showingSnippets && !core.settings.snippetsEnabled)
                || (!showingSnippets && !core.settings.clipboardEnabled) {
                core.palette.query = core.settings.clipboardEnabled ? "" : ">"
                core.palette.selection = 0
                refreshSearch()
            }
        }
        guard core.settings.clipboardEnabled else {
            watcher.stopWatching()
            return
        }
        load { [weak self] in
            guard let self, core.settings.clipboardEnabled, store.isLoaded else { return }
            watcher.startWatching()
        }
    }

    private func load(after: @escaping @MainActor () -> Void) {
        if store.isLoaded { after(); return }
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await store.load()
            loadTask = nil
            guard !Task.isCancelled else { return }
            if store.isLoaded { apply() }
            after()
        }
    }

    func show() {
        guard core.settings.clipboardEnabled || core.settings.snippetsEnabled else { return }
        if core.paletteCoordinator.isShowing(.clipboard) {
            core.paletteCoordinator.hidePalette()
            return
        }
        expandedImage = nil
        pendingActivation = nil
        contentTask?.cancel()
        searchSession.reset()
        snippetQuery = nil
        core.paletteCoordinator.showPalette(mode: .clipboard, seeding: core.settings.clipboardEnabled ? "" : ">")
        core.palette.selection = 0
        load { [weak self] in self?.refreshSearch() }
        refreshSearch()
    }

    var snippetsEnabled: Bool { core.settings.snippetsEnabled }

    func results(for query: String) -> [ClipboardResult] {
        if query.hasPrefix(">") {
            guard core.settings.snippetsEnabled else { return [] }
            if snippetQuery != query {
                snippetQuery = query
                snippetResults = snippets.matches(for: String(query.dropFirst())).map(ClipboardResult.snippet)
            }
            return snippetResults
        }
        guard core.settings.clipboardEnabled, searchSession.query == query else { return [] }
        return searchSession.items.map(ClipboardResult.item)
    }

    func refreshSearch() {
        guard core.palette.mode == .clipboard else { searchSession.cancel(); return }
        let query = core.palette.query
        if pendingActivation != query { pendingActivation = nil }
        let previous = results(for: query)
        let initialSelection = core.palette.selection
        let initialID = previous.indices.contains(initialSelection) ? previous[initialSelection].id : nil
        searchSession.search(query, items: store.items, storage: store.storage) { [weak self] previousItems in
            guard let self, core.palette.mode == .clipboard, core.palette.query == query else { return }
            let selection = core.palette.selection
            let selectedID = previousItems.indices.contains(selection) ? ClipboardResult.item(previousItems[selection]).id : nil
            let current = results(for: query)
            core.palette.selection = selectedID.flatMap { id in current.firstIndex { $0.id == id } }
                ?? min(selection, max(current.count - 1, 0))
            if pendingActivation == query, core.paletteCoordinator.isShowing(.clipboard) {
                pendingActivation = nil
                if let first = current.first { activate(first) }
            }
        }
        guard core.palette.mode == .clipboard, core.palette.query == query else { return }
        let retained = results(for: query)
        core.palette.selection = initialID.flatMap { id in retained.firstIndex { $0.id == id } }
            ?? min(initialSelection, max(retained.count - 1, 0))
    }

    func activateSelection() {
        let query = core.palette.query
        let rows = results(for: query)
        let selection = core.palette.selection
        if rows.indices.contains(selection) { activate(rows[selection]); return }
        if searchSession.isSearching || searchSession.query != query {
            pendingActivation = query
            if searchSession.query != query { refreshSearch() }
        }
    }

    func paletteDidHide() {
        pendingActivation = nil
        searchSession.cancel()
        expandedImage = nil
    }

    func snippetsChanged() {
        snippetQuery = nil
        refreshSearch()
    }

    func activate(_ result: ClipboardResult, copyOnly: Bool = false) {
        let operation: ContentOperation = switch result {
        case .item: .history
        case .snippet: .snippet
        }
        guard isEnabled(operation) else { return }
        contentTask?.cancel()
        contentOperation = operation
        let target = core.paletteCoordinator.targetApp
        let shouldPaste = !copyOnly && target != nil && target?.processIdentifier != NSRunningApplication.current.processIdentifier
        if shouldPaste, !Permissions.ensureAccessibility() { return }
        if !copyOnly { core.paletteCoordinator.hidePalette() }
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content: PreparedClipboardContent
                switch result {
                case .item(let item):
                    content = try await store.storage.prepareClipboardContent(for: item)
                    guard store.items.contains(where: { $0.id == item.id }) else { return }
                case .snippet(let snippet):
                    guard snippets.snippets.contains(where: { $0.id == snippet.id }) else { return }
                    content = .text(snippet.content)
                }
                try Task.checkCancellation()
                guard isEnabled(operation) else { return }
                let success = shouldPaste
                    ? await PasteController.paste(content, targetApplication: target)
                    : PasteController.copyToClipboard(content)
                guard !Task.isCancelled, isEnabled(operation) else { return }
                guard success else {
                    core.showMessage(shouldPaste ? "Could not paste to the previous app" : "Could not copy this item", tone: .danger)
                    return
                }
                if shouldPaste, case .item(let item) = result { store.moveToTop(item) }
                if case .snippet(let snippet) = result { snippets.recordUsage(for: snippet.id) }
            } catch is CancellationError {
            } catch { core.showMessage(error.localizedDescription, tone: .danger) }
        }
    }

    func delete(_ result: ClipboardResult) {
        switch result {
        case .item(let item): store.delete(item)
        case .snippet(let snippet): Task { await deleteSnippet(snippet) }
        }
        refreshSearch()
    }

    func editSnippet(_ result: ClipboardResult?) {
        let operation: ContentOperation = if case .item = result { .editSnippetFromHistory } else { .snippet }
        guard isEnabled(operation) else { return }
        contentTask?.cancel()
        contentOperation = operation
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target: SnippetEditorTarget
                switch result {
                case .item(let item):
                    let text = try await store.storage.loadActionText(for: item)
                    try Task.checkCancellation()
                    target = SnippetEditorTarget(snippet: nil, content: text)
                case .snippet(let snippet): target = SnippetEditorTarget(snippet: snippet)
                case nil: target = SnippetEditorTarget(snippet: nil)
                }
                try Task.checkCancellation()
                guard isEnabled(operation) else { return }
                core.paletteCoordinator.hidePalette()
                core.settingsCoordinator.showSettings(tab: .snippets)
                snippetEditor = target
            } catch is CancellationError {
            } catch { core.showMessage(error.localizedDescription, tone: .danger) }
        }
    }

    func copyImageText(_ item: ClipboardItem) {
        guard core.settings.clipboardEnabled,
              let text = item.ocrText, !text.isEmpty, text != "No text found in this image." else { return }
        PasteController.copyTextToClipboard(text)
    }

    func runOCR(_ item: ClipboardItem) {
        guard core.settings.clipboardEnabled, item.type == .image, extractingItemID == nil else { return }
        extractingItemID = item.id
        let pasteboardChange = NSPasteboard.general.changeCount
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer { extractingItemID = nil; ocrTask = nil }
            let storage = store.storage
            let image = await Task.detached(priority: .userInitiated) { storage.image(for: item) }.value
            guard !Task.isCancelled else { return }
            guard let image else { core.showMessage("Image unavailable", tone: .danger); return }
            let text = await OCRService.recognizeText(from: image) ?? ""
            guard !Task.isCancelled, core.settings.clipboardEnabled,
                  store.items.contains(where: { $0.id == item.id }) else { return }
            let extracted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setOCRText(extracted, for: item)
            guard !extracted.isEmpty else {
                core.showMessage("No text found in this image", tone: .neutral)
                return
            }
            guard NSPasteboard.general.changeCount == pasteboardChange else {
                core.showMessage("OCR ready · Clipboard changed", tone: .neutral)
                return
            }
            if PasteController.copyTextToClipboard(extracted) { core.showMessage("OCR text copied") }
            else { core.showMessage("OCR ready · Could not copy", tone: .danger) }
        }
    }

    private enum ContentOperation {
        case history, snippet, editSnippetFromHistory
    }

    private func isEnabled(_ operation: ContentOperation) -> Bool {
        switch operation {
        case .history: core.settings.clipboardEnabled
        case .snippet: core.settings.snippetsEnabled
        case .editSnippetFromHistory: core.settings.clipboardEnabled && core.settings.snippetsEnabled
        }
    }

    private func applyExpansion() {
        guard core.settings.snippetsEnabled, !isCapturingShortcut, !isRecording else {
            expansion.stop()
            ticker.unsubscribe(self)
            snippetsRunning = false
            return
        }
        ticker.subscribe(self)
        if !expansion.isRunning { expansion.stop(); expansion.start() }
        snippetsRunning = expansion.isRunning
    }

    func healthCheck() { if !expansion.isRunning { applyExpansion() } }

    func stop() {
        watcher.stopWatching()
        expansion.stop()
        ticker.unsubscribe(self)
        snippetsRunning = false
        if core.paletteCoordinator.isShowing(.clipboard) { core.paletteCoordinator.hidePalette() }
        searchSession.cancel()
        contentTask?.cancel()
        loadTask?.cancel()
        ocrTask?.cancel()
    }

    func prepareForTermination() async -> Bool {
        stop()
        await loadTask?.value
        await watcher.finishPendingProcessing()
        guard store.isLoaded else { return true }
        return await store.flush()
    }

    func clearHistory(largeFilesOnly: Bool = false) async {
        guard store.isLoaded else { return }
        let title = largeFilesOnly ? "Delete images and large text?" : "Clear clipboard history?"
        guard await core.confirm(title: title, message: nil, symbol: "trash", confirmTitle: "Delete") else { return }
        if largeFilesOnly { store.deleteImagesAndLargeText() } else { store.clear() }
    }

    func exportHistory() async {
        guard store.isLoaded else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clipboard.json"
        panel.allowedContentTypes = [.json]
        guard await panel.begin() == .OK, let url = panel.url,
              let json = await store.combinedJSONRepresentationForExport() else { return }
        do {
            try await Task.detached(priority: .utility) {
                try Data(json.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }.value
        } catch { core.showMessage("Could not export clipboard history", tone: .danger) }
    }

    func deleteSnippet(_ snippet: Snippet) async {
        guard await core.confirm(title: "Delete >\(snippet.trigger)?", message: nil, symbol: "trash", confirmTitle: "Delete") else { return }
        snippets.deleteSnippet(id: snippet.id)
        snippetsChanged()
    }
}
