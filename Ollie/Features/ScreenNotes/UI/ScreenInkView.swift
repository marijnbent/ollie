import AppKit
import QuartzCore

final class ScreenInkView: NSView {
    private static let lifetime: TimeInterval = 1
    private weak var coordinator: ScreenNoteCoordinator?
    private let displayID: UInt32
    private var link: CADisplayLink?
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private let buckets: [CAShapeLayer]

    init(frame: NSRect, displayID: UInt32, coordinator: ScreenNoteCoordinator) {
        self.displayID = displayID
        self.coordinator = coordinator
        buckets = (0..<8).map { index in
            let freshness = 1 - CGFloat(index) / 8
            let layer = CAShapeLayer()
            layer.strokeColor = ScreenInk.color
            layer.fillColor = nil
            layer.lineWidth = ScreenInk.width * (0.4 + 0.6 * freshness)
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.opacity = Float(freshness)
            return layer
        }
        super.init(frame: frame)
        wantsLayer = true
        for bucket in buckets.reversed() { layer?.addSublayer(bucket) }
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
        samples.removeAll()
        redraw(now: 0)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let inside = window.frame.contains(location)
        let point = CGPoint(x: location.x - window.frame.minX, y: location.y - window.frame.minY)
        if inside { coordinator?.samplePointer(point, displayID: displayID) }
        let moved = inside && samples.last.map { hypot(point.x - $0.point.x, point.y - $0.point.y) >= 1 } != false
        guard moved || !samples.isEmpty else { return }
        let now = link.timestamp
        samples.removeAll { now - $0.time > Self.lifetime }
        if moved { samples.append((point, now)) }
        redraw(now: now)
    }

    private func redraw(now: TimeInterval) {
        let paths = buckets.map { _ in CGMutablePath() }
        for (first, second) in zip(samples, samples.dropFirst()) {
            let age = (now - first.time) / Self.lifetime
            let path = paths[min(paths.count - 1, max(0, Int(age * Double(paths.count))))]
            path.move(to: first.point)
            path.addLine(to: second.point)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bucket, path) in zip(buckets, paths) { bucket.path = path }
        CATransaction.commit()
    }
}
