import SwiftUI

struct ClipboardScreen: PaletteScreen {
    let coordinator: ClipboardCoordinator
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [ClipboardResult] { coordinator.results(for: vm.query) }
    var primaryActionTitle: String { vm.pasteTarget?.pasteTitle ?? "Copy" }

    private func result(at selection: Int) -> ClipboardResult? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func activate(at selection: Int) {
        coordinator.activateSelection()
    }

    func secondary(at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        coordinator.activate(result, copyOnly: true)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        if shortcut == .newItem, coordinator.snippetsEnabled { coordinator.editSnippet(nil); return true }
        guard let result = result(at: selection) else { return false }
        switch shortcut {
        case .copyFile, .copyText: coordinator.activate(result, copyOnly: true)
        case .delete: coordinator.delete(result)
        case .quickLook:
            guard case .item(let item) = result, item.type == .image else { return false }
            coordinator.expandedImage = item
        default: return false
        }
        return true
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        var items = [
            PopoverMenuItem(title: primaryActionTitle, systemImage: "doc.on.clipboard", shortcut: "↩") {
                coordinator.activate(result)
            },
            PopoverMenuItem(title: "Copy", systemImage: "doc.on.doc", shortcut: "⌘C") {
                coordinator.activate(result, copyOnly: true)
            }
        ]
        switch result {
        case .item(let item):
            if item.type == .text, coordinator.snippetsEnabled {
                items.append(PopoverMenuItem(title: "Save as Snippet…", systemImage: "text.badge.plus") {
                    coordinator.editSnippet(result)
                })
            } else if item.type == .image {
                items.append(PopoverMenuItem(title: "Enlarge Image", systemImage: "arrow.up.left.and.arrow.down.right", shortcut: "⌘Y") {
                    coordinator.expandedImage = item
                })
                items.append(PopoverMenuItem(title: item.ocrText == nil ? "OCR & Copy" : "Refresh OCR & Copy", systemImage: "text.viewfinder",
                    isLoading: coordinator.extractingItemID == item.id,
                    isEnabled: coordinator.extractingItemID == nil) {
                    coordinator.runOCR(item)
                })
                items.append(PopoverMenuItem(title: "Copy Extracted Text", systemImage: "doc.on.doc",
                    isEnabled: !(item.ocrText ?? "").isEmpty && item.ocrText != "No text found in this image.") {
                    coordinator.copyImageText(item)
                })
            }
        case .snippet:
            items.append(PopoverMenuItem(title: "Edit Snippet…", systemImage: "pencil") {
                coordinator.editSnippet(result)
            })
        }
        items.append(PopoverMenuItem(title: "Delete", systemImage: "trash", startsSection: true, shortcut: "⌃X", isDestructive: true) {
            coordinator.delete(result)
        })
        return PopoverMenuContent(items: items)
    }

    func menuContent(
        at selection: Int, searchQuery: ActionMenuSearchQuery, menuSelection: Binding<Int>,
        onActivate: @escaping (Int) -> Void
    ) -> PaletteMenuContent? {
        guard let content = actions(at: selection) else { return nil }
        let filtered = content.matching(searchQuery)
        return PaletteMenuContent(
            popover: filtered.content, selection: menuSelection,
            search: PopoverMenu.Search(placeholder: "Search for actions…", placement: .top),
            onActivate: onActivate, preferredSelection: filtered.bestMatch)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(ClipboardPaletteView(
            coordinator: coordinator, vm: vm, rows: rows, selected: result(at: selection),
            scroll: scroll, openActions: openActions))
    }
}

private struct ClipboardPaletteView: View {
    @Environment(\.metrics) private var metrics
    @Environment(AppSettings.self) private var settings
    let coordinator: ClipboardCoordinator
    let vm: PaletteState
    let rows: [ClipboardResult]
    let selected: ClipboardResult?
    let scroll: ScrollIntent
    let openActions: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                            row(result, selected: result.id == selected?.id)
                                .contentShape(Rectangle())
                                .onRowClick(
                                    select: { vm.selection = index },
                                    activate: { coordinator.activate(result) })
                                .onRightClick { vm.selection = index; openActions() }
                                .id(result.id)
                        }
                    }
                    .padding(metrics.scaled(Theme.Size.paletteCardInset))
                    .scrollOriginAnchor()
                }
                .hideNativeScrollers()
                .thinScrollbar()
                .scrollFollowsSelection(scroll, row: selected?.id, atOrigin: selected?.id == rows.first?.id, proxy: proxy)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in
                    coordinator.navigationDiagnostics.scrolled()
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text(coordinator.store.error ?? (coordinator.searchSession.isSearching ? "Searching…" : "No items"))
                        .font(.system(size: metrics.scaled(12)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: metrics.scaled(Theme.Size.clipboardListWidth))
            Rectangle().fill(Theme.Colors.separator).frame(width: 1)
            ClipboardPalettePreview(result: selected, coordinator: coordinator, openActions: openActions, deferLoading: scroll.kind == .follow)
                .id(selected?.id)
        }
        .overlay {
            if let item = coordinator.expandedImage {
                ClipboardExpandedImage(item: item, coordinator: coordinator)
            }
        }
        .onChange(of: selected?.id) { coordinator.expandedImage = nil }
        .onChange(of: coordinator.store.items) { coordinator.refreshSearch() }
        .onChange(of: coordinator.snippets.snippets) { coordinator.snippetsChanged() }
        .onChange(of: coordinator.store.isLoaded) { coordinator.refreshSearch() }
        .onAppear { coordinator.refreshSearch() }
        .onDisappear { coordinator.navigationDiagnostics.stop() }
    }

    @ViewBuilder
    private func row(_ result: ClipboardResult, selected: Bool) -> some View {
        switch result {
        case .item(let item):
            ClipboardItemRow(item: item, store: coordinator.store, isSelected: selected)
        case .snippet(let snippet):
            HStack(spacing: metrics.scaled(8)) {
                Text(">\(snippet.trigger)").foregroundStyle(.secondary)
                Text(snippet.displayTitle).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: metrics.scaled(12)))
            .padding(.horizontal, metrics.scaled(8))
            .frame(height: metrics.scaled(settings.paletteDensity.clipboardRowHeight))
            .background(selected ? Theme.Colors.selection : .clear, in: RoundedRectangle(cornerRadius: metrics.scaled(5)))
        }
    }
}

private struct ClipboardPalettePreview: View {
    @Environment(\.metrics) private var metrics
    let result: ClipboardResult?
    let coordinator: ClipboardCoordinator
    let openActions: () -> Void
    let deferLoading: Bool
    @State private var text = ""
    @State private var image: NSImage?
    @State private var limit = 2_000
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result {
                HStack {
                    Text(title(result)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if case .item(let item) = result, item.type == .image {
                        if coordinator.extractingItemID == item.id { ProgressView().controlSize(.mini) }
                    }
                }
                .font(.system(size: metrics.scaled(11)))
                .padding(.horizontal, metrics.scaled(16))
                .frame(height: metrics.scaled(40))
                if case .item(let item) = result, item.type == .image {
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.scaled(12)) {
                            if let image {
                                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(5)))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: metrics.scaled(5))
                                            .strokeBorder(Theme.Colors.separator, lineWidth: 0.5)
                                    }
                                    .onTapGesture { coordinator.expandedImage = item }
                            } else {
                                Text(error ?? "Loading image…").foregroundStyle(.secondary)
                            }
                            if let text = item.ocrText {
                                Divider()
                                HStack(alignment: .top, spacing: metrics.scaled(8)) {
                                    Text(text.isEmpty ? "No text found in this image." : text)
                                        .lineSpacing(metrics.scaled(2))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if !text.isEmpty, text != "No text found in this image." {
                                        Button { coordinator.copyImageText(item) } label: {
                                            Image(systemName: "doc.on.doc")
                                                .foregroundStyle(.secondary)
                                                .frame(width: metrics.scaled(20), height: metrics.scaled(20))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy extracted text")
                                        .accessibilityLabel("Copy extracted text")
                                    }
                                }
                                .font(.system(size: metrics.scaled(12)))
                            }
                        }
                        .padding(.horizontal, metrics.scaled(16))
                        .padding(.bottom, metrics.scaled(16))
                    }
                    .hideNativeScrollers()
                    .thinScrollbar()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.scaled(12)) {
                            Text(error ?? (text.isEmpty ? String(result.text.prefix(1_000)) : text))
                                .font(.system(size: metrics.scaled(12)))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if hasMore && limit < 8_000 {
                                Button("Show more") { limit += 2_000 }
                                    .buttonStyle(.plain)
                                    .disabled(loading)
                            } else if hasMore {
                                Text("Preview limited to 8,000 characters").foregroundStyle(.secondary)
                            }
                            if case .item(let item) = result, item.isTruncated {
                                Text("Saved content is truncated").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: metrics.scaled(11)))
                        .padding(.horizontal, metrics.scaled(16))
                        .padding(.bottom, metrics.scaled(16))
                    }
                    .hideNativeScrollers()
                    .thinScrollbar()
                }
                HStack(spacing: metrics.scaled(8)) {
                    PaletteActionsButton(action: openActions)
                    Spacer()
                }
                .font(.system(size: metrics.scaled(11)))
                .padding(.horizontal, metrics.scaled(8))
                .frame(height: metrics.scaled(40))
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.Colors.separator).frame(height: 0.5)
                        .padding(.horizontal, metrics.scaled(16))
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: result?.id) {
            limit = 2_000
            text = String((result?.text ?? "").prefix(1_000))
            image = nil
            error = nil
            hasMore = false
            let navigation = result.flatMap { coordinator.navigationDiagnostics.preview(for: $0.id) }
            await load(navigation: navigation)
        }
        .task(id: limit) { if limit > 2_000 { await load() } }
    }

    private func title(_ result: ClipboardResult) -> String {
        switch result {
        case .snippet(let snippet): ">\(snippet.trigger)"
        case .item(let item):
            if let bytes = item.originalSizeBytes {
                "\(item.type == .image ? "Image" : "Text") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
            } else if item.type == .text { "Text · \((item.textContent ?? "").count) characters" }
            else { "Image" }
        }
    }

    private func load(navigation: ClipboardNavigationDiagnostics.Navigation? = nil) async {
        guard let result else { return }
        let diagnostics = coordinator.navigationDiagnostics
        let start = diagnostics.time()
        var intentionalWait = 0.0
        if let navigation {
            diagnostics.record(.previewStart, milliseconds: diagnostics.elapsed(since: navigation.started),
                               navigation: navigation)
        }
        loading = true
        defer {
            loading = false
            let duration = ClipboardNavigationDiagnostics.previewWorkMilliseconds(
                total: diagnostics.elapsed(since: start), waited: intentionalWait)
            diagnostics.record(.previewReady, milliseconds: duration,
                               navigation: navigation, outcome: Task.isCancelled ? .cancelled : .completed)
        }
        switch result {
        case .snippet(let snippet):
            text = String(snippet.content.prefix(limit))
            hasMore = snippet.content.count > limit
        case .item(let item):
            let storage = coordinator.store.storage
            if item.type == .image {
                let decodeStart = diagnostics.time()
                let loaded = await storage.imageCache.preview(for: item)
                let outcome: ClipboardNavigationDiagnostics.Outcome =
                    Task.isCancelled ? .cancelled : loaded == nil ? .unavailable : .completed
                diagnostics.record(.previewImage, milliseconds: diagnostics.elapsed(since: decodeStart),
                                   navigation: navigation, outcome: outcome)
                guard !Task.isCancelled else { return }
                image = loaded
                if loaded == nil { error = "Image unavailable" }
            } else {
                if deferLoading && (item.isFileBacked || (item.textContent?.count ?? 0) > 1_000) {
                    let waitStart = diagnostics.time()
                    do {
                        try await Task.sleep(for: .milliseconds(ClipboardNavigationDiagnostics.previewWaitMilliseconds))
                    } catch {
                        intentionalWait = diagnostics.elapsed(since: waitStart)
                        diagnostics.record(.previewWait, milliseconds: intentionalWait,
                                           navigation: navigation, outcome: .cancelled)
                        return
                    }
                    intentionalWait = diagnostics.elapsed(since: waitStart)
                    diagnostics.record(.previewWait, milliseconds: intentionalWait, navigation: navigation)
                }
                let source = storage.textChunkSource(for: item)
                let count = limit
                let readStart = diagnostics.time()
                let chunk = await Task.detached(priority: .utility) {
                    ClipboardStorage.readTextChunk(from: source, charCount: count)
                }.value
                let outcome: ClipboardNavigationDiagnostics.Outcome =
                    Task.isCancelled ? .cancelled : chunk == nil ? .unavailable : .completed
                diagnostics.record(.previewRead, milliseconds: diagnostics.elapsed(since: readStart),
                                   navigation: navigation, outcome: outcome)
                guard !Task.isCancelled else { return }
                if let chunk { text = chunk.text; hasMore = !chunk.reachedEOF }
                else { error = "Saved text unavailable" }
            }
        }
    }
}

private struct ClipboardExpandedImage: View {
    let item: ClipboardItem
    let coordinator: ClipboardCoordinator
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack {
                Spacer()
                Button("Close") { coordinator.expandedImage = nil }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .task(id: item.id) { image = await coordinator.store.storage.imageCache.preview(for: item) }
    }
}
