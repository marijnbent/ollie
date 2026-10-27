import Observation
import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    private let sessionState: DictationSessionState
    private let settingsStore: DictationSettingsStore
    private var panel: NSPanel?
    private var isShowing = false
    private var animationID = UUID()
    private var dismissal: Task<Void, Never>?
    private var streamedOverlayWidth: CGFloat?
    private var cachedCompactOverlayWidth: CGFloat?
    private var lastTargetFrame: CGRect?
    var onCycleLanguage: (() -> Void)?

    init(sessionState: DictationSessionState, settingsStore: DictationSettingsStore) {
        self.sessionState = sessionState
        self.settingsStore = settingsStore

        trackLayout()

    }

    private func trackLayout() {
        withObservationTracking {
            _ = settingsStore.showLiveTranscriptInRecorderWidget
            _ = settingsStore.showLanguageInRecorderWidget
            _ = settingsStore.overlayPosition
            _ = sessionState.lastTranscript
            _ = sessionState.recordingPhase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = synchronizeStreamedOverlayWidth()
                updateVisibleFrame()
                trackLayout()
            }
        }
    }

    func show() {
        synchronizeStreamedOverlayWidth()
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        ensureOverlayContent(on: panel)
        guard let screen = NSScreen.main else {
            sessionState.overlayPulseID = UUID()
            isShowing = true
            animationID = UUID()
            panel.orderFrontRegardless()
            return
        }

        let target = targetFrame(screen: screen)

        if isShowing {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
            lastTargetFrame = target
            return
        }

        sessionState.overlayPulseID = UUID()
        isShowing = true
        animationID = UUID()

        let offscreen = offscreenFrame(screen: screen, width: target.width, height: target.height)

        panel.alphaValue = 0
        panel.setFrame(offscreen, display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        lastTargetFrame = target
    }

    func hide() {
        guard let panel else { return }
        guard isShowing else { return }
        isShowing = false
        let hideID = animationID

        guard let screen = NSScreen.main else {
            releasePanelIfHidden(for: hideID)
            return
        }

        let target = targetFrame(screen: screen)
        let offscreen = offscreenFrame(screen: screen, width: target.width, height: target.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(offscreen, display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.releasePanelIfHidden(for: hideID)
            }
        }

        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.releasePanelIfHidden(for: hideID)
        }

    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        if let screen = NSScreen.main {
            let target = targetFrame(screen: screen)
            panel.setFrame(target, display: false)
        }

        return panel
    }

    private func ensureOverlayContent(on panel: NSPanel) {
        guard panel.contentViewController == nil else { return }

        let overlayView = OverlayView(
            sessionState: sessionState,
            settingsStore: settingsStore,
            onCycleLanguage: { [weak self] in
                self?.onCycleLanguage?()
            }
        )
        let hosting = NSHostingController(rootView: overlayView)
        panel.contentViewController = hosting

        if let contentView = panel.contentView {
            hosting.view.frame = contentView.bounds
            hosting.view.autoresizingMask = [.width, .height]
        }
    }

    private func releasePanelIfHidden(for hideID: UUID) {
        guard animationID == hideID, !isShowing else { return }
        guard let panel else { return }

        panel.orderOut(nil)
        panel.contentViewController = nil
        self.panel = nil
        streamedOverlayWidth = nil
        cachedCompactOverlayWidth = nil
        lastTargetFrame = nil
    }

    private func updateVisibleFrame() {
        guard isShowing, let panel, let screen = NSScreen.main else { return }
        let target = targetFrame(screen: screen)
        guard target != lastTargetFrame else { return }
        lastTargetFrame = target

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = target.width > panel.frame.width + 0.5 ? 0.2 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    @discardableResult
    private func synchronizeStreamedOverlayWidth() -> Bool {
        let previousWidth = streamedOverlayWidth
        let compactWidth = compactOverlayWidth
        if cachedCompactOverlayWidth != compactWidth {
            streamedOverlayWidth = nil
            cachedCompactOverlayWidth = compactWidth
        }
        if let streamedText = presentation.streamedText {
            streamedOverlayWidth = RecorderWidgetLayout.nextWidth(
                compactWidth: compactWidth,
                measuredTextWidth: RecorderWidgetLayout.measuredTextWidth(for: streamedText),
                previousWidth: streamedOverlayWidth
            )
        } else {
            streamedOverlayWidth = nil
        }
        return streamedOverlayWidth != previousWidth
    }

    private func targetFrame(screen: NSScreen) -> CGRect {
        let size = CGSize(width: min(overlayWidth, screen.frame.width - 80), height: overlayHeight)
        return settingsStore.overlayPosition.frame(size: size, on: screen)
    }

    private var overlayWidth: CGFloat {
        if let streamedText = presentation.streamedText {
            return streamedOverlayWidth ?? RecorderWidgetLayout.nextWidth(
                compactWidth: compactOverlayWidth,
                measuredTextWidth: RecorderWidgetLayout.measuredTextWidth(for: streamedText),
                previousWidth: nil
            )
        }

        return compactOverlayWidth
    }

    private var compactOverlayWidth: CGFloat {
        let baseWidth: CGFloat = sessionState.overlayAppIcon == nil ? 74 : 100
        return settingsStore.showLanguageInRecorderWidget ? baseWidth + 32 : baseWidth
    }

    private var overlayHeight: CGFloat {
        presentation.showsStreamedText ? 68 : 42
    }

    private var presentation: RecorderWidgetPresentation {
        RecorderWidgetPresentation(
            transcript: sessionState.lastTranscript,
            recordingPhase: sessionState.recordingPhase,
            isLiveTranscriptEnabled: settingsStore.showLiveTranscriptInRecorderWidget
        )
    }

    private func offscreenFrame(screen: NSScreen, width: CGFloat, height: CGFloat) -> CGRect {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let x = fullFrame.midX - width / 2
        let y: CGFloat
        switch settingsStore.overlayPosition {
        case .top:
            y = visibleFrame.maxY + 8
        case .bottom:
            y = visibleFrame.minY - height - 8
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension OverlayPosition {
    func frame(size: CGSize, on screen: NSScreen) -> CGRect {
        let y = switch self {
        case .top: screen.visibleFrame.maxY - size.height - 28
        case .bottom: screen.visibleFrame.minY + 28
        }
        return CGRect(origin: CGPoint(x: screen.frame.midX - size.width / 2, y: y), size: size)
    }
}
