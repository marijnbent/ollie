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
            if let error = dictation.session.historyPersistenceError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if dictation.session.latestRefinedEntry == nil {
                Text(dictation.settings.historyLimit == .none ? "Dictation history is off" : "No refined dictation yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.vertical, Theme.Spacing.md)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }
}
