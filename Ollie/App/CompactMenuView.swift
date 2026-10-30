import SwiftUI

struct CompactMenuView: View {
    let core: AppCore
    let close: () -> Void
    @State private var optionsHovered = false
    @State private var notificationsHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Bundle.main.appDisplayName).font(.system(size: 13, weight: .medium))
                Spacer()
                Menu {
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
            if core.settings.allows(.feature(.notifications)) {
                Button {
                    perform { core.settingsCoordinator.showSettings(tab: .notifications) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bell").frame(width: 22)
                        Text("Notifications").font(.system(size: 12, weight: .medium))
                        Spacer()
                        if core.notifications.unread > 0 {
                            Text("\(core.notifications.unread)")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                    .background(notificationsHovered ? Theme.Colors.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                }
                .buttonStyle(.plain)
                .onHover { notificationsHovered = $0 }
                .padding(.horizontal, 8)
            }
            if core.settings.allows(.feature(.network)) {
                NetworkMenuSection(network: core.network) {
                    perform { core.settingsCoordinator.showSettings(tab: .network) }
                }
            }
            if (core.settings.allows(.feature(.dictation)) && core.dictation.isBusy)
                || (core.settings.allows(.feature(.mediaImport)) && core.mediaImport.state.isImporting)
                || core.settings.allows(.feature(.notifications)) || core.settings.allows(.feature(.network)) {
                Rectangle().fill(Theme.Colors.separator).frame(height: 0.5)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
            HStack(spacing: 4) {
                if core.settings.allows(.feature(.launcher)) {
                    action("Launcher", symbol: "square.grid.2x2") { core.paletteCoordinator.showPalette(mode: .launcher) }
                }
                if core.settings.allows(.clipboardHistory) {
                    action("Clipboard", symbol: "clipboard") { core.clipboard.show() }
                }
                if core.settings.allows(.feature(.dictation)) {
                    action("Dictate", symbol: "mic") { core.dictation.toggleRecording() }
                }
                if core.settings.allows(.feature(.ai)) {
                    action("AI Chat", symbol: "sparkles") { core.aiChatCoordinator.showWindow() }
                }
                if core.settings.allows(.feature(.mediaImport)) {
                    action("Media Import", symbol: "externaldrive.badge.plus") { core.mediaImport.show() }
                }
                Spacer(minLength: 0)
                if core.settings.allows(.feature(.typingSounds)) {
                    ActionButton(title: "Typing Sounds", symbol: "speaker.wave.2", selected: true) {
                        core.settings.typingSoundsEnabled = false
                    }
                    .accessibilityValue("On")
                }
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
        var selected = false
        let run: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: run) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Theme.Colors.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(selected ? Theme.Colors.selection : hovered ? Theme.Colors.rowHover : .clear,
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
