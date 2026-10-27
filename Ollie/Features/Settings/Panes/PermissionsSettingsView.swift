import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @Environment(DictationCoordinator.self) private var dictation
    @State private var inputMonitoring = CGPreflightListenEventAccess()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                SettingsPermissionRow(title: "Accessibility",
                    subtitle: "Window switching, snippets, pasting and screen markers",
                    status: accessibilityTrusted ? "Granted" : "Not granted", isGranted: accessibilityTrusted,
                    actionTitle: "Open Settings…", anchor: .permissionsAccessibility) {
                        Permissions.openAccessibilitySettings()
                    }
            } header: {
                SettingsSectionHeader(.permissionsAccessibility)
            }
            Section("Privacy") {
                SettingsPermissionRow(title: "Microphone", subtitle: "Dictation and screen notes",
                    status: dictation.permissions.microphonePermission.rawValue,
                    isGranted: dictation.permissions.microphonePermission.isGranted,
                    actionTitle: dictation.permissions.microphonePermission.isGranted ? "Open Settings…" : "Grant Access…") {
                        dictation.permissions.requestMicrophonePermission()
                    }
                SettingsPermissionRow(title: "Input Monitoring", subtitle: "Typing sounds and window switching",
                    status: inputMonitoring ? "Granted" : "Not granted", isGranted: inputMonitoring,
                    actionTitle: "Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                SettingsPermissionRow(title: "Screen Recording", subtitle: "Window previews and screen notes",
                    status: screenRecording ? "Granted" : "Not granted", isGranted: screenRecording,
                    actionTitle: "Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.permissions)
        .task {
            while !Task.isCancelled {
                refresh()
                dictation.permissions.refreshPermissions()
                inputMonitoring = CGPreflightListenEventAccess()
                screenRecording = CGPreflightScreenCaptureAccess()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func refresh() {
        let trusted = Permissions.isAccessibilityTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }
}
