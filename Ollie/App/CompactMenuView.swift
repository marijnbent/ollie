import SwiftUI

struct CompactMenuView: View {
    let core: AppCore
    let close: () -> Void
    let paste: (String) -> Void
    @State private var optionsHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Bundle.main.appDisplayName).font(.system(size: 13, weight: .medium))
                Spacer()
                if core.settings.allows(.feature(.dictation)) {
                    Button("History", systemImage: "clock.arrow.circlepath") {
                        perform { core.dictation.showHistory() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
                Menu {
                    if core.settings.allows(.feature(.launcher)) {
                        Button("Launcher", systemImage: "square.grid.2x2") {
                            perform { core.paletteCoordinator.showPalette(mode: .launcher) }
                        }
                    }
                    if core.settings.allows(.feature(.ai)) {
                        Button("AI Chat", systemImage: "sparkles") { perform { core.aiChatCoordinator.showWindow() } }
                    }
                    if core.settings.allows(.feature(.mediaImport)) {
                        Button("Media Import", systemImage: "externaldrive.badge.plus") { perform { core.mediaImport.show() } }
                    }
                    if core.settings.allows(.feature(.notifications)) {
                        Button(core.notifications.unread > 0 ? "Notifications (\(core.notifications.unread))" : "Notifications",
                               systemImage: "bell") {
                            perform { core.settingsCoordinator.showSettings(tab: .notifications) }
                        }
                    }
                    if core.settings.allows(.feature(.network)) {
                        Button("Network", systemImage: "network") {
                            perform { core.settingsCoordinator.showSettings(tab: .network) }
                        }
                    }
                    if core.settings.allows(.feature(.typingSounds)) {
                        Button("Turn Off Typing Sounds", systemImage: "speaker.slash") {
                            core.settings.typingSoundsEnabled = false
                        }
                    }
                    Divider()
                    if core.settings.allows(.screenExplanation) {
                        Button("Screen Note", systemImage: "mic.badge.plus") { perform { core.screenNotes.toggle() } }
                    }
                    Button("Check for Updates…") { perform { core.updateCoordinator.checkForUpdates() } }
                    Button("About \(Bundle.main.appDisplayName)") { perform { core.settingsCoordinator.showAbout() } }
                    Divider()
                    Button("Restart \(Bundle.main.appDisplayName)") { perform { core.restart() } }
                    Button("Quit \(Bundle.main.appDisplayName)") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(optionsHovered ? Theme.Colors.rowHover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("App options")
                .onHover { optionsHovered = $0 }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 42)
            if core.settings.allows(.feature(.dictation)), core.dictation.isBusy {
                HStack(spacing: 10) {
                    Image(systemName: core.dictation.session.isRecording ? "waveform" : "ellipsis").foregroundStyle(.red)
                    Text(core.dictation.fileTranscription.isBusy && !core.dictation.session.isRecording
                         ? core.dictation.fileTranscription.processingLabel : core.dictation.session.statusMessage)
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    if core.dictation.session.isRecording {
                        Button("Stop") { core.dictation.toggleRecording() }.controlSize(.small)
                    }
                    Button("Cancel") { core.dictation.cancelRecording() }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            if core.settings.allows(.feature(.mediaImport)), core.mediaImport.state.isImporting {
                HStack(spacing: 10) {
                    ProgressView(value: core.mediaImport.state.overallImportProgress).frame(width: 38)
                    Text("Importing \(core.mediaImport.state.completedCount)/\(core.mediaImport.state.totalImportCount)")
                        .font(.system(size: 11)).monospacedDigit()
                    Spacer()
                    Button("Cancel") { core.mediaImport.state.cancelImport() }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if core.settings.allows(.feature(.dictation)) {
                DictationMenuSection(paste: paste)
                    .environment(core.dictation)
            }
            if core.settings.allows(.feature(.dictation))
                || (core.settings.allows(.feature(.mediaImport)) && core.mediaImport.state.isImporting) {
                Rectangle().fill(Theme.Colors.separator).frame(height: 0.5)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
            HStack(spacing: 4) {
                if core.settings.allows(.feature(.dictation)) {
                    action("Dictate", symbol: "mic") { core.dictation.toggleRecording() }
                }
                if core.settings.allows(.clipboardHistory) {
                    action("Clipboard", symbol: "clipboard") { core.clipboard.show() }
                }
                Spacer(minLength: 0)
                action("Settings", symbol: "gearshape") { core.settingsCoordinator.showSettings() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
        .background(HUDGlassBackground().allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Size.floatingRadius, style: .continuous))
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        ActionButton(title: title, symbol: symbol) { perform(run) }
    }

    private struct ActionButton: View {
        let title: String
        let symbol: String
        let run: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: run) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(hovered ? Theme.Colors.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.barControl))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(title)
            .accessibilityLabel(title)
        }
    }

    private func perform(_ action: () -> Void) {
        close()
        action()
    }
}
