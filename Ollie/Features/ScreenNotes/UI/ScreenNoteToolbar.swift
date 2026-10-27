import SwiftUI

struct ScreenNoteToolbar: View {
    @Environment(ScreenNoteCoordinator.self) private var drawing
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        HStack(spacing: Theme.Spacing.md) {
            ForEach(ScreenInk.Tool.allCases, id: \.self) { tool in
                Button {
                    settings.screenNotesTool = tool
                    if !drawing.drawingEnabled { drawing.toggleDrawing() }
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: Theme.Size.screenNotesControl, height: Theme.Size.screenNotesControl)
                        .background(settings.screenNotesTool == tool ? Theme.Colors.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.barControl))
                }
                .help(tool == .pen ? "Pen (P)" : "Arrow (A or Shift-drag)")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(settings.screenNotesTool == tool ? .isSelected : [])
            }
            Divider().frame(height: Theme.Size.screenNotesSwatch)
            ForEach(ScreenInk.Color.allCases, id: \.self) { color in
                Button {
                    settings.screenNotesColor = color
                } label: {
                    Circle().fill(Color(cgColor: color.cgColor))
                        .overlay {
                            if settings.screenNotesColor == color {
                                Circle().strokeBorder(Theme.Colors.textPrimary, lineWidth: 2)
                            }
                        }
                        .frame(width: Theme.Size.screenNotesSwatch, height: Theme.Size.screenNotesSwatch)
                }
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(settings.screenNotesColor == color ? .isSelected : [])
            }
            Menu {
                Picker("Width", selection: $settings.screenNotesWidth) {
                    ForEach(ScreenInk.Width.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if !drawing.isNarrating {
                    Picker("Clear ink after", selection: $settings.screenNotesLifetime) {
                        ForEach(ScreenInk.Lifetime.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Width and auto-clear")
            .accessibilityLabel("Drawing options")
            button("Undo (⌘Z)", symbol: "arrow.uturn.backward") { drawing.undo() }.disabled(!drawing.canUndo)
            button("Clear (Delete)", symbol: "trash") { drawing.clear() }.disabled(!drawing.canUndo)
            if drawing.isNarrating {
                Divider().frame(height: Theme.Size.screenNotesSwatch)
                Image(systemName: "waveform").foregroundStyle(.red)
                    .help("Recording on \(drawing.displayName)")
                    .accessibilityLabel("Recording on \(drawing.displayName)")
                button(drawing.drawingEnabled ? "Use apps (D)" : "Draw (D)",
                       symbol: drawing.drawingEnabled ? "cursorarrow" : "pencil.tip.crop.circle") {
                    drawing.toggleDrawing()
                }
                Button { drawing.snap() } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "camera")
                        Text("\(drawing.shotCount)").monospacedDigit()
                    }
                    .frame(height: Theme.Size.screenNotesControl)
                }
                .disabled(!drawing.canSnap)
                .help("Take screenshot (Space)")
                .accessibilityLabel("Take screenshot; \(drawing.shotCount) captured")
                button("Done (Return)", symbol: "checkmark") { drawing.finishNote() }
            }
            button("Close (Esc)", symbol: "xmark") { drawing.stop() }
        }
        .buttonStyle(.plain)
        .font(.system(size: Theme.Size.screenNotesFont, weight: .medium))
        .padding(Theme.Spacing.md)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.menuPanel))
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
