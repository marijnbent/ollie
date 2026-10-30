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
            shiftCap
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
        .help("Hold Shift to draw. Esc cancels; Super Caps Lock or the shortcut finishes")
    }

    private var shiftCap: some View {
        Text("⇧")
            .font(Theme.Typography.keyCap)
            .foregroundStyle(note.drawing ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minWidth: Theme.Size.recorderKeyCap, minHeight: Theme.Size.recorderKeyCap)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous)
                    .fill(note.drawing ? Color(cgColor: ScreenInk.color) : Color.primary.opacity(0.08))
            )
            .scaleEffect(note.drawing ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: note.drawing)
            .help("Hold Shift and move the pointer to draw")
            .accessibilityLabel("Hold Shift to draw")
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(RecorderWidgetButtonStyle())
            .help(title)
            .accessibilityLabel(title)
    }
}
