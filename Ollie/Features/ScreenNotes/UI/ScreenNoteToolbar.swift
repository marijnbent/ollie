import SwiftUI

struct ScreenNoteToolbar: View {
    @Environment(ScreenNoteCoordinator.self) private var note
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RecordingStatusOrb(audioMeter: note.audioMeter, isEnhancing: false)
            Text("\(note.shotCount)").monospacedDigit()
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.88 : 0.66))
                .frame(minWidth: Theme.Size.screenNotesCount)
                .accessibilityLabel("\(note.shotCount) screenshots")
            HStack(spacing: Theme.Spacing.xs) {
                button("Cancel", symbol: "xmark") { note.stop() }
                button("Finish and copy", symbol: "checkmark") { note.finishNote() }
            }
        }
        .font(.system(size: Theme.Size.screenNotesFont, weight: .medium, design: .rounded))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Spacing.xl)
        .modifier(OverlayCardSurface(cornerRadius: 17))
        .scaleEffect(appear ? 1 : 0.96)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : -8)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72, blendDuration: 0.2)) {
                appear = true
            }
        }
        .help("Hold ⌥ and drag to mark; use the shortcut again to finish")
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RecorderWidgetButtonStyle())
            .help(title)
            .accessibilityLabel(title)
    }
}
