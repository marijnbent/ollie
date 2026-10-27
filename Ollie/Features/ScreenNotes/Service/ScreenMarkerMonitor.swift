import AppKit

@MainActor
final class ScreenMarkerMonitor {
    private var global: Any?
    private var local: Any?
    private var generation = UUID()

    func start(onChange: @escaping @MainActor (Bool) -> Void,
               onClick: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        let generation = generation
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .leftMouseDown]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let flags = event.type == .flagsChanged ? event.modifierFlags.contains(.option) : nil
            let point = event.type == .leftMouseDown ? event.cgEvent?.location : nil
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                if let flags { onChange(flags) }
                if let point { onClick(point) }
            }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.type == .flagsChanged { onChange(event.modifierFlags.contains(.option)) }
            if event.type == .leftMouseDown, !(event.window is ScreenNotePanel), let point = event.cgEvent?.location {
                onClick(point)
            }
            return event
        }
        onChange(NSEvent.modifierFlags.contains(.option))
    }

    func stop() {
        generation = UUID()
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    isolated deinit { stop() }
}
