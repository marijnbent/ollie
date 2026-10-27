import SwiftUI

struct ScreenNoteToolbar: View {
    @Environment(ScreenNoteCoordinator.self) private var note

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "record.circle.fill").foregroundStyle(Color(cgColor: ScreenInk.color))
                .accessibilityLabel("Recording")
            Text("\(note.shotCount)").monospacedDigit()
                .accessibilityLabel("\(note.shotCount) screenshots")
            Spacer(minLength: 0)
            button("Cancel", symbol: "xmark") { note.stop() }
            button("Finish and copy", symbol: "checkmark") { note.finishNote() }
        }
        .buttonStyle(.plain)
        .font(.system(size: Theme.Size.screenNotesFont, weight: .medium))
        .padding(Theme.Spacing.md)
        .glassEffect(.regular, in: Capsule())
        .help("Hold ⌥ and drag to mark; use the shortcut again to finish")
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Theme.Size.screenNotesControl, height: Theme.Size.screenNotesControl)
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
    }
}
