import SwiftUI

struct OnboardingView: View {
    @State var step = 0
    @Environment(OnboardingCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(HotKeyManager.self) private var hotKeys
    @Environment(DictationPermissionService.self) private var permissions

    static let width: CGFloat = 520
    static let initialSize = CGSize(width: width, height: 440)

    var body: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            Text(step == 0 ? "Welcome to Ollie" : "Permissions")
                .font(.title2.weight(.bold))
            if step == 0 {
                shortcuts
            } else {
                access
            }
            if let error = coordinator.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.top, Theme.Spacing.lg)
        .padding([.horizontal, .bottom], Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            coordinator.fit(height: $0)
        }
        .background(
            LinearGradient(
                colors: [Theme.Colors.sheen, Color.clear],
                startPoint: .top, endPoint: .center
            ).ignoresSafeArea()
        )
        .shortcutRecorderPopoverHost()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshShortcuts()
        }
        .onDisappear { hotKeys.recordingAction = nil }
        .task {
            while !Task.isCancelled {
                permissions.refreshPermissions()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var shortcuts: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            OnboardingCard {
                OnboardingRow(title: "App Launcher", systemImage: "magnifyingglass", tint: .blue) {
                    HStack(spacing: Theme.Spacing.md) {
                        if hotKeys.binding(for: .togglePalette) == nil {
                            Button("Use ⌘Space", action: coordinator.useCommandSpace)
                                .controlSize(.small)
                                .fixedSize()
                        }
                        ShortcutRecorder(action: .togglePalette)
                    }
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Spotlight",
                    subtitle: "For ⌘Space: turn off Show Spotlight search, then click Done.",
                    systemImage: "keyboard", tint: .blue
                ) {
                    Button("Open Settings") { coordinator.openSettings(.spotlight) }
                        .controlSize(.small)
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Fn / Globe",
                    subtitle: "For Fn dictation: set Press fn/Globe key to Do Nothing in Keyboard settings.",
                    systemImage: "globe", tint: .blue
                ) {
                    Button("Open Settings") { coordinator.openSettings(.keyboard) }
                        .controlSize(.small)
                }
                OnboardingDivider()
                OnboardingRow(title: "Launch at login", systemImage: "power", tint: .green) {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            caption(
                "Only change macOS shortcuts you want Ollie to use. To restore them later, return to these settings; "
                + "turning off an Ollie feature does not undo macOS changes."
            )
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            OnboardingCard {
                OnboardingRow(
                    title: "Accessibility", subtitle: "Paste text and use modifier-key shortcuts.",
                    systemImage: "accessibility", tint: .blue
                ) {
                    if permissions.accessibilityPermission.isGranted {
                        granted
                    } else {
                        Button("Grant Access", action: permissions.requestAccessibilityPermission)
                            .controlSize(.small)
                    }
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Microphone", subtitle: "Only needed for dictation.",
                    systemImage: "mic", tint: .orange
                ) {
                    if permissions.microphonePermission.isGranted {
                        granted
                    } else {
                        Button("Grant Access") { permissions.requestMicrophonePermission() }
                            .controlSize(.small)
                    }
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "Dictation",
                    subtitle: "Optional. Choose Fn or another shortcut and add your transcription API key.",
                    systemImage: "waveform", tint: .orange
                ) {
                    Button("Set Up…", action: coordinator.setUpDictation)
                        .controlSize(.small)
                }
            }
            caption("You can skip these and return through Settings › General › Setup. Raycast import is in Settings › Backup.")
        }
    }

    private var footer: some View {
        HStack {
            if step == 1 {
                Button("Back") { step = 0 }
                    .buttonStyle(.plain)
            }
            Text("\(step + 1) of 2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(step == 0 ? "Continue" : "Get Started") {
                hotKeys.recordingAction = nil
                if step == 0 { step = 1 } else { coordinator.finishOnboarding() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var granted: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
