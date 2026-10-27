import SwiftUI

struct ScreenNotesSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(CommandCatalog.entries(ownedBy: .screenNotes)) { LauncherItemRow(entry: $0) }
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.screenNotes)
    }
}
