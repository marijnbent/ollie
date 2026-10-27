import AppKit
import QuartzCore

final class ScreenInkView: NSView {
    weak var coordinator: ScreenNoteCoordinator?
    let displayID: UInt32
    private let strokeLayer = CAShapeLayer()
    private var activePath = CGMutablePath()

    init(frame: NSRect, displayID: UInt32, coordinator: ScreenNoteCoordinator) {
        self.displayID = displayID
        self.coordinator = coordinator
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strokeLayer.strokeColor = ScreenInk.color
        strokeLayer.fillColor = nil
        strokeLayer.lineWidth = ScreenInk.width
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        layer?.addSublayer(strokeLayer)
        setAccessibilityLabel("Screen marker")
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        coordinator?.begin(at: convert(event.locationInWindow, from: nil), displayID: displayID)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.append(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.append(convert(event.locationInWindow, from: nil))
        coordinator?.finishMark()
    }

    override func scrollWheel(with event: NSEvent) {}

    func setMarking(_ enabled: Bool) {
        layer?.borderColor = ScreenInk.color.copy(alpha: 0.35)
        layer?.borderWidth = enabled ? 2 : 0
    }

    func begin(_ point: CGPoint) {
        strokeLayer.removeAllAnimations()
        activePath = CGMutablePath()
        activePath.move(to: point)
        strokeLayer.path = activePath
    }

    func append(_ point: CGPoint) {
        activePath.addLine(to: point)
        strokeLayer.path = activePath
    }

    func fade() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.6
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        strokeLayer.add(animation, forKey: "fade")
    }
}
