#if DEBUG
import AppKit
import SwiftUI

@MainActor enum OllieVerification {
    static func runIfRequested() -> Bool {
        if CommandLine.arguments.contains("--preview-ollie-onboarding") {
            guard Bundle.main.bundleIdentifier == "nl.bentjes.ollie.verification" else { exit(2) }
            NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            AppCore.shared.onboardingCoordinator.showOnboarding()
            return true
        }
        if CommandLine.arguments.contains("--verify-ollie-launcher") {
            guard Bundle.main.bundleIdentifier == "nl.bentjes.ollie.verification" else { exit(2) }
            Task {
                do {
                    try await LauncherInputVerification.run()
                    exit(0)
                } catch {
                    print("VERIFY FAILED: \(error)")
                    exit(1)
                }
            }
            return true
        }
        let preview = CommandLine.arguments.contains("--preview-ollie-settings")
        guard preview || CommandLine.arguments.contains("--verify-ollie-ui") else { return false }
        guard Bundle.main.bundleIdentifier == "nl.bentjes.ollie.verification" else { exit(2) }
        enableFeatures()
        if preview {
            AppCore.shared.settingsCoordinator.showSettings()
            return true
        }
        NSApp.setActivationPolicy(.prohibited)
        Task {
            do { try await run(); exit(0) }
            catch { print("VERIFY FAILED: \(error)"); exit(1) }
        }
        return true
    }

    private static func run() async throws {
        let core = AppCore.shared
        let output = URL(fileURLWithPath: "/tmp/ollie-native-verify", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"
            for tab in SettingsTab.available {
                let navigation = SettingsNavigationState(tab: tab)
                let presenter = SettingsEditorPresenter(core: core, navigation: navigation)
                let view = SettingsRootView().settingsEnvironment(core: core, navigation: navigation, editorPresenter: presenter)
                try await capture(view, size: CGSize(width: 980, height: 720), to: output.appendingPathComponent("\(tab)-\(suffix).png"))
            }
            try await capture(CompactMenuView(core: core, close: {}), size: CGSize(width: 320, height: 160),
                to: output.appendingPathComponent("menu-\(suffix).png"))
        }
        print("PASS: mounted \(SettingsTab.available.count) native settings panes and captured compact menu in both appearances")
    }

    private static func enableFeatures() {
        let core = AppCore.shared
        core.settings.launcherEnabled = true
        core.settings.clipboardEnabled = true
        core.settings.snippetsEnabled = true
        core.settings.dictationEnabled = true
        core.settings.windowSwitcherEnabled = true
        core.settings.spacesEnabled = true
        core.settings.typingSoundsEnabled = true
        core.settings.aiEnabled = true
        core.settings.mediaImportEnabled = true
        core.settings.networkEnabled = true
        core.settings.notificationsEnabled = true
    }

    private static func capture<V: View>(_ view: V, size: CGSize, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.coderInvalidValue) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try png.write(to: url)
        print("Rendered \(url.lastPathComponent) \(Int(host.frame.width))×\(Int(host.frame.height))")
    }
}
#endif
