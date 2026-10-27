import AppKit
import QuartzCore

final class ScreenInkView: NSView {
    weak var coordinator: ScreenNoteCoordinator?
    let displayID: UInt32
    private var finished: [UUID: CAShapeLayer] = [:]
    private var activeLayer: CAShapeLayer?
    private var activeID: UUID?
    private var activePath = CGMutablePath()
    private var pointCount = 0
    private let inkLayer = CALayer()

    init(frame: NSRect, displayID: UInt32, coordinator: ScreenNoteCoordinator) {
        self.displayID = displayID
        self.coordinator = coordinator
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.insertSublayer(inkLayer, at: 0)
        setAccessibilityLabel("Screen drawing")
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        coordinator?.begin(at: convert(event.locationInWindow, from: nil), displayID: displayID,
                           arrow: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.append(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.append(convert(event.locationInWindow, from: nil))
        coordinator?.finish()
    }

    override func rightMouseDown(with event: NSEvent) { coordinator?.stop() }

    func showActive(_ stroke: ScreenInk.Stroke?) {
        guard let stroke, stroke.displayID == displayID else {
            activeLayer?.removeFromSuperlayer()
            activeLayer = nil
            activeID = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if activeID != stroke.id {
            activeLayer?.removeFromSuperlayer()
            let shape = shape(for: stroke)
            inkLayer.addSublayer(shape)
            activeLayer = shape
            activeID = stroke.id
            activePath = CGMutablePath()
            if let first = stroke.points.first { activePath.move(to: first) }
            pointCount = 1
        }
        if stroke.tool == .pen, stroke.points.count > 1 {
            for point in stroke.points.dropFirst(pointCount) { activePath.addLine(to: point) }
            pointCount = stroke.points.count
            activeLayer?.path = activePath
        } else {
            activeLayer?.path = stroke.path
        }
        CATransaction.commit()
    }

    func sync(_ strokes: [ScreenInk.Stroke], now: TimeInterval) {
        let visible = strokes.filter { $0.displayID == displayID }
        let ids = Set(visible.map(\.id))
        for id in Array(finished.keys) where !ids.contains(id) {
            finished.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for stroke in visible where finished[stroke.id] == nil {
            let shape = shape(for: stroke)
            shape.path = stroke.path
            inkLayer.addSublayer(shape)
            finished[stroke.id] = shape
            if let expiry = stroke.expiresAt {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.beginTime = shape.convertTime(now, from: nil)
                    + max(0, expiry - now - ScreenInk.fadeDuration)
                fade.duration = ScreenInk.fadeDuration
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                shape.add(fade, forKey: "fade")
            }
        }
    }

    private func shape(for stroke: ScreenInk.Stroke) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.strokeColor = stroke.color.cgColor
        shape.fillColor = nil
        shape.lineWidth = CGFloat(stroke.width.rawValue)
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }
}
