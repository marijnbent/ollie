import AppKit
import SwiftUI

@MainActor
@Observable
final class ScreenNoteCoordinator {
    enum Phase { case idle, recording, finishing, copying }

    private unowned let core: AppCore
    private var settings: AppSettings { core.settings }
    private(set) var phase = Phase.idle
    private(set) var shotCount = 0
    private(set) var drawing = false
    @ObservationIgnored private var ink = ScreenInk()
    @ObservationIgnored private var shiftAnchor: (point: CGPoint, displayID: UInt32)?
    @ObservationIgnored private var activeFrame: UUID?
    @ObservationIgnored private var activeContext: ScreenNote.Context?
    @ObservationIgnored private var note: ScreenNote?
    @ObservationIgnored private var panels: [ScreenNotePanel] = []
    @ObservationIgnored private var toolbar: ScreenNotePanel?
    @ObservationIgnored private var canvases: [UInt32: ScreenInkView] = [:]
    @ObservationIgnored private var observations: [NotificationToken] = []
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var frames: [UUID: Task<ScreenNoteCapture.Frame, Error>] = [:]
    @ObservationIgnored private var pendingCaptures = 0
    @ObservationIgnored private var pointerDisplay: UInt32?
    @ObservationIgnored private var pointerArrival: TimeInterval?
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var publishedDirectory: URL?
    @ObservationIgnored private var fingerprints: [UInt32: Data] = [:]
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var transcriptResult: TranscriptHandOff.Result?
    @ObservationIgnored private var warning: String?
    @ObservationIgnored private var limitShown = false

    var isActive: Bool { phase != .idle }
    var audioMeter: AudioMeterState { core.dictation.session.audioMeter }

    init(core: AppCore) { self.core = core }

    func apply() {
        if !settings.screenNotesEnabled || !settings.dictationEnabled { stop() }
    }

    func toggle() {
        if phase == .recording { finishNote(); return }
        guard phase == .idle, settings.screenNotesEnabled, settings.dictationEnabled,
              let screen = NSScreen.underCursor, let displayID = Self.displayID(screen) else { return }
        if let issue = core.dictation.handOffUnavailableReason() {
            core.showMessage(issue, tone: .neutral)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            core.showMessage("Allow Screen Recording in System Settings, then try Screen Note again.", tone: .neutral)
            return
        }
        let id = UUID()
        let directory = AppPaths.caches().appending(path: "ScreenNotes/\(id.uuidString)", directoryHint: .isDirectory)
        note = ScreenNote(id: id, directory: directory)
        startedAt = CACurrentMediaTime()
        shotCount = 0
        warning = nil
        limitShown = false
        transcriptResult = nil
        fingerprints.removeAll()
        phase = .recording
        let start = core.dictation.beginHandOff(TranscriptHandOff(id: id, requestFinish: { [weak self] in
            guard let self, self.note?.id == id else { return }
            self.finishNote()
        }, finish: { [weak self] result in
            guard let self, self.note?.id == id else { return }
            if case .cancelled = result { self.stop(); return }
            self.transcriptResult = result
            if self.phase == .recording { self.finishNote() }
            self.publishIfReady()
        }))
        switch start {
        case .started:
            guard note?.id == id else { return }
            showPanels(toolbarScreen: screen)
            _ = selectContext(displayID: displayID)
            observe(NSApplication.didChangeScreenParametersNotification, center: .default, context: false)
            observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter, context: false)
            observe(NSWorkspace.sessionDidResignActiveNotification, center: NSWorkspace.shared.notificationCenter, context: false)
            observe(NSWorkspace.didActivateApplicationNotification, center: NSWorkspace.shared.notificationCenter, context: true)
            observe(NSWorkspace.activeSpaceDidChangeNotification, center: NSWorkspace.shared.notificationCenter, context: true)
            enqueue(.start)
        case .unavailable(let message):
            stop()
            core.showMessage(message, tone: .neutral)
        }
    }

    func pointerTick(_ point: CGPoint, displayID: UInt32) {
        guard phase == .recording else { return }
        trackDisplay(displayID)
        let modifiers = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
        let held = modifiers == .shift && NSEvent.pressedMouseButtons == 0
        if drawing != held { drawing = held }
        if let stroke = ink.active {
            if held && stroke.displayID == displayID { append(point) } else { finishMark() }
            return
        }
        guard held else { shiftAnchor = nil; return }
        guard let anchor = shiftAnchor, anchor.displayID == displayID else {
            shiftAnchor = (point, displayID)
            return
        }
        guard hypot(point.x - anchor.point.x, point.y - anchor.point.y) >= 4 else { return }
        guard note?.canCapture(.marked, pending: pendingCaptures) == true else { showLimit(); return }
        begin(at: anchor.point, displayID: displayID)
        append(point)
    }

    private func trackDisplay(_ displayID: UInt32) {
        let elapsed = CACurrentMediaTime() - startedAt
        if pointerDisplay != displayID {
            pointerDisplay = displayID
            pointerArrival = elapsed
        } else if let arrival = pointerArrival, elapsed - arrival >= 0.5 {
            pointerArrival = nil
            if note?.contexts.last?.displayID != displayID { contextChanged(displayID: displayID) }
        }
    }

    private func begin(at point: CGPoint, displayID: UInt32) {
        guard let context = selectContext(displayID: displayID) else { return }
        activeContext = context
        ink.begin(at: point, displayID: displayID)
        activeFrame = startFrame(context: context)
        canvases[displayID]?.begin(point)
    }

    private func append(_ point: CGPoint) {
        let count = ink.active?.points.count
        ink.append(point)
        if let stroke = ink.active, stroke.points.count != count { canvases[stroke.displayID]?.append(point) }
    }

    private func finishMark() {
        shiftAnchor = nil
        guard let stroke = ink.finish(), let frame = activeFrame, let context = activeContext else { return }
        activeFrame = nil
        activeContext = nil
        canvases[stroke.displayID]?.fade()
        enqueue(.marked, context: context, stroke: stroke, frameID: frame)
    }

    private func startFrame(context: ScreenNote.Context) -> UUID {
        let id = UUID()
        let excluded = panels.map(\.windowNumber) + [toolbar?.windowNumber].compactMap { $0 }
        frames[id] = Task {
            try await ScreenNoteCapture.frame(displayID: context.displayID, excludedWindows: excluded)
        }
        return id
    }

    private func enqueue(_ kind: ScreenNote.Kind, context: ScreenNote.Context? = nil,
                         stroke: ScreenInk.Stroke? = nil, frameID: UUID? = nil) {
        guard let note, let context = context ?? note.contexts.last else { return }
        guard note.canCapture(kind, pending: pendingCaptures) else {
            if let frameID { frames.removeValue(forKey: frameID)?.cancel() }
            if kind == .marked { showLimit() }
            return
        }
        let frameID = frameID ?? startFrame(context: context)
        guard let frame = frames[frameID] else { return }
        let id = note.id
        let elapsed = CACurrentMediaTime() - startedAt
        let previous = captureTask
        pendingCaptures += 1
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let image = try await frame.value
                try Task.checkCancellation()
                guard self.note?.id == id, let current = self.note else { return }
                let file = current.directory.appendingPathComponent(String(format: "Shot %02d.png", current.shots.count + 1))
                let result = try await Task.detached(priority: .userInitiated) {
                    try ScreenNoteCapture.save(image, strokes: stroke.map { [$0] } ?? [], file: file)
                }.value
                try Task.checkCancellation()
                guard self.note?.id == id else { return }
                if kind != .marked, fingerprints[image.displayID] == result.fingerprint {
                    try FileManager.default.removeItem(at: file)
                } else if self.note?.append(.init(file: file, elapsed: elapsed, byteCount: result.byteCount,
                                                 kind: kind, contextID: context.id)) == true {
                    shotCount = self.note?.shots.count ?? 0
                    fingerprints[image.displayID] = result.fingerprint
                } else {
                    try FileManager.default.removeItem(at: file)
                    showLimit()
                }
            } catch {
                guard !Task.isCancelled, self.note?.id == id else { return }
                warning = "A screenshot could not be captured."
                if kind == .start {
                    stop()
                    core.showMessage(error.localizedDescription, tone: .danger)
                    return
                }
                core.showMessage(error.localizedDescription, tone: .danger)
            }
            guard self.note?.id == id else { return }
            frames.removeValue(forKey: frameID)
            pendingCaptures -= 1
            publishIfReady()
        }
    }

    private func showLimit() {
        warning = "The screenshot limit was reached."
        guard !limitShown else { return }
        limitShown = true
        core.showMessage("Screenshot limit reached. Narration continues.", tone: .neutral)
    }

    private func selectContext(displayID: UInt32? = nil, force: Bool = false) -> ScreenNote.Context? {
        let elapsed = note?.contexts.isEmpty == true ? 0 : CACurrentMediaTime() - startedAt
        guard let proposed = ScreenNoteCapture.context(elapsed: elapsed, displayID: displayID) else { return nil }
        if !force, let current = note?.contexts.last,
           current.appName == proposed.appName, current.displayID == proposed.displayID { return current }
        finishMark()
        note?.contexts.append(proposed)
        return proposed
    }

    private func contextChanged(displayID: UInt32? = nil, force: Bool = false) {
        guard phase == .recording else { return }
        let previous = note?.contexts.last?.id
        guard let context = selectContext(displayID: displayID, force: force), context.id != previous else { return }
        contextTask?.cancel()
        let id = note?.id
        contextTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.note?.id == id, self.phase == .recording, self.ink.active == nil,
                  self.note?.contexts.last?.id == context.id else { return }
            self.enqueue(.switched, context: context)
        }
    }

    func finishNote() {
        guard phase == .recording, let id = note?.id else { return }
        finishMark()
        drawing = false
        phase = .finishing
        for canvas in canvases.values { canvas.stop() }
        contextTask?.cancel()
        toolbar?.orderOut(nil)
        core.showProgress("Transcribing…", onCancel: { [weak self] in self?.stop() })
        core.dictation.endHandOff(id: id)
        enqueue(.final)
        publishIfReady()
    }

    private func publishIfReady() {
        guard phase == .finishing, pendingCaptures == 0,
              let result = transcriptResult, var prepared = note else { return }
        switch result {
        case .transcript(let text, let spans, let issue):
            prepared.transcript = text
            prepared.speech = spans.map { $0.shifted(by: -startedAt) }
            warning = issue ?? warning
            if !text.isEmpty && prepared.speech.isEmpty { warning = "Speech timing unavailable." }
        case .failed(let issue): warning = issue
        case .cancelled: stop(); return
        }
        let completed = prepared
        phase = .copying
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try ScreenNoteClipboard.prepare(completed)
                }.value
                try Task.checkCancellation()
                guard note?.id == completed.id, settings.screenNotesEnabled, settings.dictationEnabled else { return }
                guard ScreenNoteClipboard.write(payload, to: .general) else { throw CocoaError(.fileWriteUnknown) }
                publishedDirectory = completed.directory
                let message = completed.transcript.isEmpty
                    ? "Copied \(completed.shots.count) screenshots; no speech captured."
                    : "Copied screen note."
                let issue = warning
                stop()
                core.showMessage(issue == nil ? message : message + " Speech or capture may be incomplete.",
                                 tone: issue == nil ? .success : .neutral)
                pruneOutputs(keeping: completed.directory)
            } catch {
                guard !Task.isCancelled, note?.id == completed.id else { return }
                stop()
                core.showMessage("Could not copy the screen note.", tone: .danger)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        let id = note?.id
        let directory = note?.directory
        let hadProgress = phase == .finishing || phase == .copying
        phase = .idle
        note = nil
        if let id { core.dictation.cancelHandOff(id: id) }
        let pendingCapture = captureTask
        let pendingExport = exportTask
        let pendingFrames = Array(frames.values)
        captureTask?.cancel()
        exportTask?.cancel()
        contextTask?.cancel()
        for frame in pendingFrames { frame.cancel() }
        for canvas in canvases.values { canvas.stop() }
        captureTask = nil
        exportTask = nil
        contextTask = nil
        frames.removeAll()
        activeFrame = nil
        activeContext = nil
        pendingCaptures = 0
        observations.removeAll()
        for panel in panels { panel.orderOut(nil); panel.contentView = nil }
        toolbar?.orderOut(nil)
        toolbar?.contentView = nil
        toolbar = nil
        panels.removeAll()
        canvases.removeAll()
        ink = ScreenInk()
        shiftAnchor = nil
        drawing = false
        pointerDisplay = nil
        pointerArrival = nil
        if hadProgress { core.hideProgress() }
        if let directory, directory != publishedDirectory {
            let previous = cleanupTask
            cleanupTask = Task {
                await previous?.value
                await pendingCapture?.value
                await pendingExport?.value
                for frame in pendingFrames { _ = try? await frame.value }
                _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
            }
        }
    }

    func prepareForTermination() async {
        stop()
        await cleanupTask?.value
    }

    private func pruneOutputs(keeping directory: URL) {
        let previous = cleanupTask
        cleanupTask = Task { [weak self] in
            await previous?.value
            let entries = await Task.detached(priority: .utility) {
                (try? FileManager.default.contentsOfDirectory(
                    at: directory.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            }.value
            let activeDirectory = self?.note?.directory
            let publishedDirectory = self?.publishedDirectory
            let stale = entries.filter {
                $0 != directory && $0 != activeDirectory && $0 != publishedDirectory
                    && UUID(uuidString: $0.lastPathComponent) != nil
            }
            _ = await Task.detached(priority: .utility) {
                for entry in stale { try? FileManager.default.removeItem(at: entry) }
            }.value
        }
    }

    private func showPanels(toolbarScreen: NSScreen) {
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(screen) else { continue }
            let panel = ScreenNotePanel(screen: screen)
            let canvas = ScreenInkView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       displayID: displayID, coordinator: self)
            panel.contentView = canvas
            panel.ignoresMouseEvents = true
            canvases[displayID] = canvas
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let panel = ScreenNotePanel(screen: toolbarScreen)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let host = NSHostingView(rootView: ScreenNoteToolbar().environment(self))
        host.sizingOptions = []
        panel.contentView = host
        panel.hasShadow = true
        panel.setFrame(core.dictation.settings.overlayPosition.frame(size: Theme.Size.screenNotesToolbar,
                                                                     on: toolbarScreen), display: false)
        panel.orderFrontRegardless()
        toolbar = panel
    }

    static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, context: Bool) {
        let session = note?.id
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.note?.id == session else { return }
                if context {
                    self.contextChanged(force: name == NSWorkspace.activeSpaceDidChangeNotification)
                } else { self.stop() }
            }
        }
        observations.append(NotificationToken(token, center: center))
    }
}
