import SwiftUI

struct ScreenNotesSettingsView: View {
    @Environment(ScreenNoteCoordinator.self) private var drawing
    @Environment(AppSettings.self) private var settings
    @Environment(SettingsNavigationState.self) private var navigation

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(CommandCatalog.entries(ownedBy: .screenNotes)) { LauncherItemRow(entry: $0) }
                if settings.dictationEnabled {
                    Menu("Explain Screen") {
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            Button(screen.localizedName) { drawing.explain(on: screen) }
                        }
                    }
                    .disabled(drawing.isActive)
                } else {
                    Button("Configure Dictation…") { navigation.select(.features) }
                }
                Button(drawing.isActive ? "Cancel" : "Draw on Screen") {
                    if drawing.isActive { drawing.stop() } else { drawing.toggle() }
                }
                Button("Copy Last Screen Note") { drawing.copyLastNote() }
                    .disabled(drawing.lastNote == nil || drawing.isActive)
                Button("Copy Last Note Text") { drawing.copyLastNote(textOnly: true) }
                    .disabled(drawing.lastNote == nil || drawing.isActive)
            } header: { SettingsSectionHeader(.screenNotesCommands) }
            Section {
                Picker(selection: $settings.screenNotesTool) {
                    ForEach(ScreenInk.Tool.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { SettingsRowTitle(.screenNotesInk, "Tool") }
                Picker(selection: $settings.screenNotesColor) {
                    ForEach(ScreenInk.Color.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingsRowTitle(.screenNotesInk, "Color") }
                Picker(selection: $settings.screenNotesWidth) {
                    ForEach(ScreenInk.Width.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingsRowTitle(.screenNotesInk, "Width") }
                Picker(selection: $settings.screenNotesLifetime) {
                    ForEach(ScreenInk.Lifetime.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { SettingsRowTitle(.screenNotesInk, "Drawing-only auto-clear") }
            } header: { SettingsSectionHeader(.screenNotesInk) }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.screenNotes)
    }
}
