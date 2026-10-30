import AppKit
import QuartzCore

final class ScreenInkView: NSView {
    private weak var coordinator: ScreenNoteCoordinator?
    private let displayID: UInt32
    private var link: CADisplayLink?
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
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        guard window.frame.contains(location) else { return }
        coordinator?.pointerTick(CGPoint(x: location.x - window.frame.minX, y: location.y - window.frame.minY),
                                 displayID: displayID)
    }

    func begin(_ point: CGPoint) {
        strokeLayer.removeAllAnimations()
        activePath = CGMutablePath()
        activePath.move(to: point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.path = activePath
        CATransaction.commit()
    }

    func append(_ point: CGPoint) {
        activePath.addLine(to: point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokeLayer.path = activePath
        CATransaction.commit()
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
