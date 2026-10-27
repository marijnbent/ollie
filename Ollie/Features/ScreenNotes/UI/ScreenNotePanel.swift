import AppKit
import Carbon.HIToolbox

final class ScreenNotePanel: NSPanel {
    weak var coordinator: ScreenNoteCoordinator?

    init(screen: NSScreen, coordinator: ScreenNoteCoordinator) {
        self.coordinator = coordinator
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape: coordinator?.stop()
        case kVK_Return, kVK_ANSI_KeypadEnter: coordinator?.finishNote()
        case kVK_Delete, kVK_ForwardDelete: coordinator?.clear()
        case kVK_ANSI_Z where modifiers == .command: coordinator?.undo()
        default:
            guard modifiers.isEmpty || modifiers == .shift else { return }
            coordinator?.handleKey(event.charactersIgnoringModifiers?.lowercased() ?? "")
        }
    }
}
