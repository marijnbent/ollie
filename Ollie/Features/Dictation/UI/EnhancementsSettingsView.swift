import SwiftUI

private struct PromptEditorRequest: Identifiable {
    let id: UUID
}

private struct OverridePickerRequest: Identifiable {
    let shortcutID: UUID

    var id: UUID { shortcutID }
}

private extension PromptConfig {
    var previewText: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No prompt content yet." }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}

private struct PromptEditorPanel: View {
    @Binding var prompt: PromptConfig
    @Environment(\.settingsEditorDismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(title: "Edit Prompt")
            Form {
                Section {
                    TextField("Name", text: $prompt.name)
                    Picker("Provider", selection: $prompt.provider) {
                        ForEach(EnhancementProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: prompt.provider) { _, provider in prompt.model = provider.defaultModel }
                    TextField("Model", text: $prompt.model, prompt: Text("Model ID"))
                }
                Section {
                    TextEditor(text: $prompt.content)
                        .frame(minHeight: Theme.Size.editorTextHeight * 1.5)
                        .accessibilityLabel("Prompt instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("The transcript is appended inside <transcription> tags.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Button("Done") { dismiss() }
                .buttonStyle(.modalAction(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth, height: Theme.Size.settingsPickerHeight)
        .settingsEditorPanelSurface(controlsOnGlass: false)
    }
}

struct EnhancementsSettingsView: View {
    @Bindable var viewModel: DictationEnhancementsController

    @State private var pickerModel = DictationAppPickerState()
    @State private var promptEditorRequest: PromptEditorRequest?
    @State private var overridePickerRequest: OverridePickerRequest?

    var body: some View {
        Group {
            providerSection
            promptLibrarySection
            routingSections
        }

    }

    @ViewBuilder
    private var providerSection: some View {
        Section {
            SettingsRow(title: "OpenRouter") {
                RevealableSecureField(title: "OpenRouter API key", text: viewModel.binding(for: \.openRouterApiKey), prompt: Text("API key"))
                    .labelsHidden()
                    .frame(width: Theme.Size.settingsSecretWidth)
            }
            SettingsRow(title: "Celeris") {
                RevealableSecureField(title: "Celeris API key", text: viewModel.binding(for: \.celerisApiKey), prompt: Text("API key"))
                    .labelsHidden()
                    .frame(width: Theme.Size.settingsSecretWidth)
            }
            SettingsRow(title: "Mercury") {
                RevealableSecureField(
                    title: "Mercury API key", text: viewModel.binding(for: \.mercuryApiKey), prompt: Text("API key")
                )
                    .labelsHidden()
                    .frame(width: Theme.Size.settingsSecretWidth)
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Add each API key once. Choose the provider and model in each prompt.")
        }
    }

    private var promptLibrarySection: some View {
        Section("Prompt Library") {
            if viewModel.prompts.isEmpty {
                Text("No prompts yet").foregroundStyle(.secondary)
            }
            ForEach(viewModel.prompts) { prompt in
                SettingsRow(title: prompt.displayName,
                    subtitle: "\(prompt.provider.displayName) · \(prompt.model.trimmed.isEmpty ? "No model" : prompt.model.trimmed)\n\(prompt.previewText)",
                    subtitleLineLimit: 2) {
                    Button("Edit…") { promptEditorRequest = PromptEditorRequest(id: prompt.id) }
                    SettingsRemoveButton(label: "Delete \(prompt.displayName)", deletesContent: true) {
                        viewModel.deletePrompt(id: prompt.id)
                    }
                }
                .help(prompt.previewText + "\n" + viewModel.promptUsageSummary(for: prompt.id))
            }
            Button("Add Prompt…") {
                let prompt = viewModel.addPrompt()
                promptEditorRequest = PromptEditorRequest(id: prompt.id)
            }
            .settingsEditorPanel(item: $promptEditorRequest) { request in
                Group {
                    if let promptBinding = viewModel.bindingForPromptID(request.id) {
                        PromptEditorPanel(prompt: promptBinding)
                    } else {
                        Text("Prompt not found.")
                            .padding(Theme.Spacing.dialogInset)
                            .frame(width: Theme.Size.editorSheetWidth)
                            .settingsEditorPanelSurface()
                    }
                }
            }
            .settingsEditorPanel(item: $overridePickerRequest) { request in
                RunningAppPickerPanel(model: pickerModel) { app in
                    viewModel.upsertAppPromptOverride(
                        shortcutID: request.shortcutID,
                        appBundleIdentifier: app.bundleIdentifier,
                        appDisplayName: app.displayName
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var routingSections: some View {
        ForEach(viewModel.shortcuts) { shortcut in
            if let shortcutBinding = viewModel.bindingForShortcutID(shortcut.id) {
                Section {
                    Picker("Default prompt", selection: shortcutBinding.promptID) {
                        Text("None").tag(UUID?.none)
                        ForEach(viewModel.prompts) { prompt in
                            Text(prompt.displayName).tag(Optional(prompt.id))
                        }
                    }

                    ForEach(Array(shortcutBinding.wrappedValue.appPromptOverrides.indices), id: \.self) { index in
                        HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                            BundleIconView(
                                bundleIdentifier: shortcutBinding.wrappedValue.appPromptOverrides[index].appBundleIdentifier,
                                bundleURL: nil,
                                size: SettingsListMetrics.iconSize
                            )

                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(shortcutBinding.wrappedValue.appPromptOverrides[index].appDisplayName)
                                    .font(.body)
                                Text(shortcutBinding.wrappedValue.appPromptOverrides[index].appBundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Picker(
                                "Prompt",
                                selection: Binding(
                                    get: { shortcutBinding.wrappedValue.appPromptOverrides[index].promptID },
                                    set: { newValue in
                                        var updated = shortcutBinding.wrappedValue
                                        updated.appPromptOverrides[index].promptID = newValue
                                        shortcutBinding.wrappedValue = updated
                                    }
                                )
                            ) {
                                ForEach(viewModel.prompts) { prompt in
                                    Text(prompt.displayName).tag(prompt.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 200)
                            .labelsHidden()

                            SettingsRemoveButton(label: "Remove app prompt") {
                                var updated = shortcutBinding.wrappedValue
                                updated.appPromptOverrides.remove(at: index)
                                shortcutBinding.wrappedValue = updated
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    Button("Add App…") {
                        overridePickerRequest = OverridePickerRequest(shortcutID: shortcut.id)
                    }
                    .disabled(viewModel.prompts.isEmpty)
                } header: {
                    Text("\(shortcut.key.displayName) · \(shortcut.mode.displayName)")
                } footer: {
                    if shortcut.appPromptOverrides.isEmpty {
                        Text(viewModel.prompts.isEmpty
                             ? "Create a prompt before adding per-app overrides."
                             : "Only running apps appear in the picker. Overrides stay saved even when the app is not running.")
                    }
                }
            }
        }
    }
}
