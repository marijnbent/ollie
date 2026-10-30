import SwiftUI

struct HistoryView: View {
    @Environment(DictationCoordinator.self) private var dictation
    @Bindable var viewModel: DictationHistoryController

    var body: some View {
        let entries = viewModel.transcriptHistory
        let retryLanguages = viewModel.retryTranscriptionLanguages

        Group {
            Section {
                Button("Transcribe File…", systemImage: "waveform.badge.plus") {
                    dictation.showFileTranscription()
                }
            }
            if entries.isEmpty {
                emptyState
            } else {
                Section {
                    LazyVStack(spacing: Theme.Spacing.xl) {
                        ForEach(entries) { entry in
                            HistoryEntryCard(
                                entry: entry,
                                isExpanded: viewModel.isExpanded(entry.id),
                                isRetrying: viewModel.isRetrying(entry.id),
                                retryError: viewModel.retryError(for: entry.id),
                                retryLanguages: retryLanguages,
                                onToggleExpansion: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        viewModel.toggleExpansion(entry.id)
                                    }
                                },
                                onCopy: viewModel.copy,
                                onRetryTranscription: { language in
                                    viewModel.retryTranscription(for: entry, language: language)
                                },
                                onRetryEnhancement: {
                                    viewModel.retryEnhancement(for: entry)
                                }
                            )
                            if entry.id != entries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        Section {
            Text(viewModel.historyLimit == .none ? "History is off" : "No transcriptions yet")
                .foregroundStyle(.secondary)
            if viewModel.historyLimit == .none {
                Text("Choose a history limit in Recording to save transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HistoryEntryCard: View {
    let entry: TranscriptHistoryEntry
    let isExpanded: Bool
    let isRetrying: Bool
    let retryError: String?
    let retryLanguages: [DeepgramLanguage]
    let onToggleExpansion: () -> Void
    let onCopy: (String) -> Void
    let onRetryTranscription: (DeepgramLanguage) -> Void
    let onRetryEnhancement: () -> Void

    private var original: String { entry.text.trimmed }
    private var enhanced: String { entry.enhancedText?.trimmed ?? "" }
    private var hasRetryActions: Bool { entry.canRetryTranscription || entry.canRetryEnhancement }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let transcriptionError = entry.transcriptionError {
                issue(
                    title: "Transcription error",
                    message: transcriptionError,
                    showsIcon: entry.shouldShowTranscriptionWarningIcon
                )
            }

            if let enhancementError = entry.enhancementError {
                issue(title: "Enhancement error", message: enhancementError)
            }

            if let retryError {
                issue(title: "Retry error", message: retryError)
            }

            transcriptContent

            if hasRetryActions {
                retryActions
            }
        }

    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let fileName = entry.sourceFileName {
                Text(fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fileName)
            }
            Text(entry.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 12)

            if let promptName = promptName {
                Label(promptName, systemImage: "wand.and.stars")
                    .lineLimit(1)
                    .help(savedPromptHelp)
            }

            if entry.promptName != nil || entry.savedEnhancementPromptLabel != nil {
                Text(entry.promptSourceLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if !original.isEmpty, !enhanced.isEmpty {
            transcript(
                title: "Original",
                text: original,
                systemImage: "waveform",
                isEmphasized: false
            )
            transcript(
                title: "Enhanced",
                text: enhanced,
                systemImage: "sparkles",
                isEmphasized: true
            )
        } else if !enhanced.isEmpty {
            transcript(title: nil, text: enhanced, systemImage: "sparkles", isEmphasized: true)
        } else if !original.isEmpty {
            transcript(title: nil, text: original, systemImage: "waveform", isEmphasized: false)
        }
    }

    private func transcript(
        title: String?,
        text: String,
        systemImage: String,
        isEmphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                if let title {
                    Text(title)
                }
                Spacer()
                Button {
                    onCopy(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy \(title?.lowercased() ?? "transcript")")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isEmphasized ? Color.accentColor : .secondary)

            Text(text)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 4)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(
            isEmphasized
                ? Color.accentColor.opacity(0.07)
                : Color(nsColor: .textBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpansion)
        .help(isExpanded ? "Collapse transcript" : "Expand transcript")
    }

    private func issue(title: String, message: String, showsIcon: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showsIcon {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var retryActions: some View {
        HStack(spacing: 12) {
            if entry.canRetryTranscription {
                Menu {
                    ForEach(retryLanguages) { language in
                        Button(language.displayName) {
                            onRetryTranscription(language)
                        }
                    }
                } label: {
                    Label("Transcribe again", systemImage: "waveform")
                }
                .menuStyle(.borderlessButton)
                .disabled(isRetrying)
                .help("Choose a language and transcribe the saved recording again")
            }

            if entry.canRetryEnhancement {
                Button(action: onRetryEnhancement) {
                    Label("Enhance again", systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .help("Retry enhancement")
            }

            Spacer()

            if isRetrying {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.caption)
    }

    private var promptName: String? {
        if let promptName = entry.promptName?.trimmed, !promptName.isEmpty {
            return promptName
        }
        return entry.savedEnhancementPromptLabel
    }

    private var savedPromptHelp: String {
        entry.enhancementPromptText?.trimmed ?? promptName ?? ""
    }
}
