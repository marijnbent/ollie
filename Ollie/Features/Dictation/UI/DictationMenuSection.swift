import SwiftUI

struct DictationMenuSection: View {
    @Environment(DictationCoordinator.self) private var dictation
    let paste: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let entry = dictation.session.latestRefinedEntry, let text = entry.refinedText {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        Label("Latest refined", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(entry.timestamp, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Spacing.md) {
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            dictation.historyControls.copy(text)
                        }
                        Button("Paste", systemImage: "arrow.up.doc") { paste(text) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            ForEach(dictation.session.recentMenuEntries) { entry in
                RecentTranscriptRow(entry: entry) { paste(entry.pasteText) }
            }
            if let error = dictation.session.historyPersistenceError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if dictation.session.latestRefinedEntry == nil && dictation.session.recentMenuEntries.isEmpty {
                Text(dictation.settings.historyLimit == .none ? "Dictation history is off" : "No dictation history yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.vertical, Theme.Spacing.md)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private struct RecentTranscriptRow: View {
        let entry: TranscriptHistoryEntry
        let paste: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: paste) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: entry.refinedText == nil ? "waveform" : "sparkles")
                        .frame(width: 16)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(entry.pasteText)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(entry.timestamp, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.doc")
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                .background(hovered ? Theme.Colors.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.barControl))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("Paste \(entry.pasteText)")
        }
    }
}
