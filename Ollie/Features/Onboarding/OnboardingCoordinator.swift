import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class OnboardingCoordinator {
    enum SettingsDestination: String {
        case spotlight = "com.apple.Keyboard-Settings.extension?Spotlight"
        case keyboard = "com.apple.Keyboard-Settings.extension"
    }

    private let window: AppWindowController
    private unowned let core: AppCore
    private(set) var error: String?

    init(core: AppCore) {
        self.core = core
        window = AppWindowController(
            title: "Welcome to Ollie", contentSize: OnboardingView.initialSize,
            activation: core.activationPolicy)
    }

    func fit(height: CGFloat) {
        window.fitContent(width: OnboardingView.width, height: height)
    }

    func showOnboarding() {
        error = nil
        window.show {
            OnboardingView()
                .environment(self)
                .environment(self.core.settings)
                .environment(self.core.hotKeys)
                .environment(self.core.dictation.permissions)
        }
    }

    func useCommandSpace() {
        let binding = HotKeyBinding.combo(KeyShortcut(carbonKeyCode: kVK_Space, carbonModifiers: cmdKey))
        if let owner = core.hotKeys.conflictOwner(of: binding, excluding: .togglePalette) {
            error = "⌘Space is already assigned to \(owner). Choose another shortcut."
            return
        }
        error = nil
        core.hotKeys.setBinding(binding, for: .togglePalette)
    }

    func openSettings(_ destination: SettingsDestination) {
        guard let url = URL(string: "x-apple.systempreferences:\(destination.rawValue)"),
              NSWorkspace.shared.open(url) else {
            error = "Could not open System Settings. Open Keyboard settings from the Apple menu."
            return
        }
        error = nil
    }

    func setUpDictation() {
        core.settings.dictationEnabled = true
        core.settingsCoordinator.showSettings(tab: .dictation)
    }

    func refreshShortcuts() {
        core.hotKeys.refreshRegistrations()
    }

    func finishOnboarding() {
        core.hotKeys.recordingAction = nil
        window.close()
        if core.settings.launcherEnabled {
            core.paletteCoordinator.showPalette(mode: .launcher)
        }
    }

    func focusExisting() -> Bool {
        window.focus()
    }
}
