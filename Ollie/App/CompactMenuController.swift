import AppKit
import SwiftUI

@MainActor
final class CompactMenuController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var item: NSStatusItem?
    private var panel: CompactMenuPanel?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?

    init(core: AppCore) {
        self.core = core
    }

    func applyVisibility() {
        guard core.settings.showInMenuBar || !core.settings.launcherEnabled else {
            stop()
            return
        }
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(named: "MenuBarIcon")
        item.button?.toolTip = Bundle.main.appDisplayName
        item.button?.setAccessibilityLabel(Bundle.main.appDisplayName)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
    }

    @objc private func toggle() {
        guard panel?.isVisible != true else {
            close()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        if core.settings.allows(.feature(.dictation)) { core.dictation.loadHistory() }
        if panel == nil {
            let panel = CompactMenuPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.onEscape = { [weak self] in self?.close() }
            let host = NSHostingView(rootView: CompactMenuView(
                core: core, close: { [weak self] in self?.close() },
                paste: { [weak self] text in
                    guard let self else { return }
                    close()
                    core.dictation.pasteHistoryText(text, into: previousApp)
                })
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.resize(height: size.height)
                })
            host.sizingOptions = []
            panel.contentView = host
            self.panel = panel
        }
        resize(height: panel?.frame.height ?? 100)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(nil)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func resize(height: CGFloat) {
        guard let button = item?.button, let window = button.window, let panel else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let width: CGFloat = 320
        let size = CGSize(width: width, height: max(80, height))
        let x = max(screen.minX + 8, min(anchor.maxX - width, screen.maxX - width - 8))
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: anchor.minY - size.height - 6), size: size), display: true)
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
    }

    func stop() {
        close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

private final class CompactMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
