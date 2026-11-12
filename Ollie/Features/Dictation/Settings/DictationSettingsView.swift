import SwiftUI

struct DictationSettingsView: View {
    @Environment(DictationCoordinator.self) private var dictation

    var body: some View {
        @Bindable var dictation = dictation
        Form {
            if dictation.session.isRecording || dictation.conflict != nil
                || dictation.settings.credentialError != nil || dictation.session.historyPersistenceError != nil {
                Section {
                    if dictation.session.isRecording {
                        SettingsRow(title: "Recording") {
                            Button("Stop") { dictation.toggleRecording() }
                        }
                    }
                    if let conflict = dictation.conflict {
                        SettingsNotice("Shortcut already used by \(conflict)", isError: false)
                    }
                    if let error = dictation.settings.credentialError { SettingsNotice(error) }
                    if let error = dictation.session.historyPersistenceError { SettingsNotice(error) }
                }
            }
            switch dictation.settingsPane {
            case .general: DictationGeneralSettingsView(viewModel: dictation.generalControls)
            case .shortcuts: ShortcutsSettingsView(viewModel: dictation.shortcutControls)
            case .enhancements: EnhancementsSettingsView(viewModel: dictation.enhancementControls)
            case .history: HistoryView(viewModel: dictation.historyControls)
            case .logs: LogsView(viewModel: dictation.logControls)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Dictation settings", selection: $dictation.settingsPane) {
                ForEach(DictationCoordinator.SettingsPane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.md)
        }
        .settingsScrollTarget(.dictation)
        .task { dictation.prepareSettings() }
    }
}
