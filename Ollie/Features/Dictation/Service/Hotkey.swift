import AppKit

struct Hotkey: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(shortcutKey: ShortcutKey) {
        self.keyCode = shortcutKey.keyCode
        let deviceMask: UInt = switch shortcutKey {
        case .fn: 0
        case .leftControl: 0x0001
        case .leftCommand: 0x0008
        case .rightCommand: 0x0010
        case .rightOption: 0x0040
        }
        self.modifiers = NSEvent.ModifierFlags(rawValue: shortcutKey.modifierFlag.rawValue | deviceMask)
    }
}
