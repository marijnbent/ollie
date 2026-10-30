import AppKit
import SwiftUI

@MainActor
final class FileTranscriptionHostingView<Content: View>: NSHostingView<Content> {
    private let canImport: () -> Bool
    private let receive: (NSPasteboard) -> Bool
    private let targeted: (Bool) -> Void
    private let pasteboard: () -> NSPasteboard

    init(
        rootView: Content, canImport: @escaping () -> Bool,
        receive: @escaping (NSPasteboard) -> Bool, targeted: @escaping (Bool) -> Void,
        pasteboard: @escaping () -> NSPasteboard = { .general }
    ) {
        self.canImport = canImport
        self.receive = receive
        self.targeted = targeted
        self.pasteboard = pasteboard
        super.init(rootView: rootView)
        sizingOptions = []
        registerForDraggedTypes(TranscriptionFileImport.draggedTypes)
    }

    @available(*, unavailable)
    required init(rootView: Content) { fatalError() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = canImport() && TranscriptionFileImport.canRead(sender.draggingPasteboard)
        targeted(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canImport() && TranscriptionFileImport.canRead(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        targeted(false)
        return canImport() && receive(sender.draggingPasteboard)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            if canImport() { _ = receive(pasteboard()) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        if canImport() { _ = receive(pasteboard()) }
    }

}
