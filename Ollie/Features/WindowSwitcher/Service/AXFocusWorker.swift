import ApplicationServices
import Darwin
import Foundation

struct AXWindowTarget: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement
}

enum AXWindowAction: Sendable {
    case unminimize
    case raise
    case makeMain
    case focus
    case close
}

struct AXFocusWorker: Sendable {
    private let lock = NSLock()
    private let action: @Sendable (AXWindowAction, AXWindowTarget) -> AXError
    private let focused: @Sendable (AXWindowTarget) -> Bool

    init(
        action: @escaping @Sendable (AXWindowAction, AXWindowTarget) -> AXError = AXFocusWorker.performSystemAction,
        focused: @escaping @Sendable (AXWindowTarget) -> Bool = AXFocusWorker.readSystemFocus
    ) {
        self.action = action
        self.focused = focused
    }

    func perform(_ action: AXWindowAction, target: AXWindowTarget) async -> AXError {
        await run(pid: target.pid) { [self] in

        guard !Task.isCancelled else { return .cannotComplete }
        return self.action(action, target)

        }
    }

    func isFocused(_ target: AXWindowTarget) async -> Bool {
        await run(pid: target.pid) { [self] in

        guard !Task.isCancelled else { return false }
        return focused(target)

        }
    }

    func windowID(for target: AXWindowTarget) async -> CGWindowID? {
        await run(pid: target.pid) {

        guard !Task.isCancelled,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let getWindow = unsafeBitCast(symbol, to: GetWindow.self)
        AXUIElementSetMessagingTimeout(target.element, AXWindowReader.defaultMessagingTimeout)
        var windowID: CGWindowID = 0
        guard getWindow(target.element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID

        }
    }

    func closeWindow(pid: pid_t, target: AXWindowTarget?) async -> AXError {
        await run(pid: pid) { [self] in

        guard !Task.isCancelled else { return .cannotComplete }
        if let target { return self.action(.close, target) }
        let app = AXUIElementCreateApplication(pid)
        let reader = AXWindowReader()
        reader.prepareForSnapshot(app)
        guard let element = reader.windowAttribute(kAXFocusedWindowAttribute, on: app)
            ?? reader.windowAttribute(kAXMainWindowAttribute, on: app) else {
            return .noValue
        }
        return self.action(.close, AXWindowTarget(pid: pid, element: element))

        }
    }

    private func run<T: Sendable>(pid: pid_t, _ operation: @escaping @Sendable () -> T) async -> T {
        if pid == getpid() { return await MainActor.run(body: operation) }
        let task = Task.detached(priority: .userInitiated) { [lock] in lock.withLock(operation) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func readSystemFocus(_ target: AXWindowTarget) -> Bool {
        let app = AXUIElementCreateApplication(target.pid)
        let reader = AXWindowReader()
        reader.prepareForSnapshot(app)
        guard let focused = reader.windowAttribute(kAXFocusedWindowAttribute, on: app) else { return false }
        return CFEqual(target.element, focused)
    }

    private static func performSystemAction(_ action: AXWindowAction, target: AXWindowTarget) -> AXError {
        let window = target.element
        AXUIElementSetMessagingTimeout(window, AXWindowReader.defaultMessagingTimeout)
        switch action {
        case .unminimize:
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        case .raise:
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        case .makeMain:
            return AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        case .focus:
            return AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case .close:
            guard let button = AXWindowReader().windowAttribute(kAXCloseButtonAttribute, on: window) else {
                return .noValue
            }
            AXUIElementSetMessagingTimeout(button, AXWindowReader.defaultMessagingTimeout)
            return AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }
}
