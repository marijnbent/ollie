import AppKit

@MainActor
final class ScreenMarkerMonitor {
    private var global: Any?
    private var local: Any?

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = .flagsChanged
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { onChange(event.modifierFlags.contains(.option)) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            onChange(event.modifierFlags.contains(.option))
            return event
        }
        onChange(NSEvent.modifierFlags.contains(.option))
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    isolated deinit { stop() }
}
