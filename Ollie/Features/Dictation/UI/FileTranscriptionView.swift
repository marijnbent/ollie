import AppKit
import SwiftUI

struct FileTranscriptionView: View {
    @Environment(DictationCoordinator.self) private var dictation

    private var state: FileTranscriptionController { dictation.fileTranscription }
    private var provider: TranscriptionProviderSettings { dictation.settings.transcriptionProviderSettings }
    private var displayedProvider: TranscriptionProvider { state.activeProvider ?? provider.provider }
    private var missingCredential: Bool {
        state.stagedFile != nil && state.result == nil && provider.apiKey.isEmpty && !state.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(Theme.Spacing.xxl)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            Divider()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay {
            if dictation.isFileDropTargeted && !state.isBusy {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colors.dropTarget, style: StrokeStyle(
                        lineWidth: Theme.Size.dropHintStroke, dash: [Theme.Size.dropHintDash]
                    ))
                    .padding(Theme.Spacing.md)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: dictation.settings.transcriptionProvider, initial: true) {
            dictation.setFileTranscriptionLanguage(state.language)
        }
        .onChange(of: state.isTranscribing) {
            if !state.isBusy { dictation.setFileTranscriptionLanguage(state.language) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if let file = state.stagedFile {
                fileRow(file).fixedSize(horizontal: false, vertical: true)
            }
            if missingCredential {
                SettingsNotice("Add your \(provider.provider.displayName) API key in Dictation settings.")
                Button("Open Settings…") { dictation.showFileTranscriptionSettings() }
            } else if let error = state.error {
                SettingsNotice(error)
            }
            if state.isBusy {
                ProgressView(state.processingLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = state.result {
                ScrollView {
                    Text(result.text)
                        .textSelection(.enabled)
                        .lineSpacing(Theme.Spacing.xxs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.xl)
                }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                dropWell
            }
        }
    }

    private func fileRow(_ file: URL) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Size.fileTranscriptionIcon, height: Theme.Size.fileTranscriptionIcon)
            Text(file.lastPathComponent)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: Theme.Spacing.md)
            if !state.isBusy {
                Button { dictation.clearTranscriptionFile() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear file")
                .help("Clear file")
            }
        }
    }

    private var dropWell: some View {
        VStack(spacing: Theme.Spacing.xl) {
            if state.stagedFile == nil {
                Image(systemName: "waveform")
                    .font(.system(size: Theme.Size.noteEmptyGlyph))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(state.stagedFile == nil ? "Drop an audio file" : "Drop another audio file")
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Spacing.md) {
                chooseFileButton
                Button("Paste") { dictation.pasteTranscriptionFile() }
                    .help("Paste audio file (⌘V)")
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(displayedProvider.displayName)
                .foregroundStyle(.secondary)
            Picker("Language", selection: Binding(
                get: { state.language }, set: { dictation.setFileTranscriptionLanguage($0) }
            )) {
                ForEach(displayedProvider.languageOptions) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: Theme.Size.fileTranscriptionLanguageWidth)
            .lineLimit(1)
            .help(state.language.displayName)
            .disabled(state.isBusy)
            Button { dictation.showFileTranscriptionSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(state.isBusy)
            .accessibilityLabel("Dictation settings")
            .help("Dictation settings")
            Spacer(minLength: Theme.Spacing.md)
            actions
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.xl)
    }

    @ViewBuilder
    private var actions: some View {
        if state.isBusy {
            Button("Cancel") { dictation.cancelFileTranscription() }
                .keyboardShortcut(.cancelAction)
        } else if let result = state.result {
            chooseFileButton
            Button("Copy", systemImage: "doc.on.doc") { dictation.copyFileTranscript(result.text) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(state.error == nil ? "Transcribe" : "Try Again") { dictation.transcribeStagedFile() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.stagedFile == nil || missingCredential)
        }
    }

    private var chooseFileButton: some View {
        Button("Choose File…") { dictation.chooseTranscriptionFile() }
            .keyboardShortcut("o")
    }
}

@MainActor
final class FileTranscriptionWindowChrome: WindowChrome {
    static let identifier = NSUserInterfaceItemIdentifier("FileTranscription")

    func install(in window: NSWindow) {
        window.identifier = Self.identifier
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
    }
}
