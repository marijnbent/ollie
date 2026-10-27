import AppKit
import SwiftUI

@MainActor
@Observable
final class ScreenNoteCoordinator {
    enum Phase { case idle, drawing, starting, recording, finishing, copying }

    private unowned let core: AppCore
    private var settings: AppSettings { core.settings }
    private(set) var phase = Phase.idle
    private(set) var drawingEnabled = false
    private(set) var canUndo = false
    private(set) var shotCount = 0
    private(set) var captureBusy = false
    private(set) var displayName = ""
    private(set) var lastNote: ScreenNote?
    @ObservationIgnored private var ink = ScreenInk()
    @ObservationIgnored private var note: ScreenNote?
    @ObservationIgnored private var targetScreen: NSScreen?
    @ObservationIgnored private var panels: [ScreenNotePanel] = []
    @ObservationIgnored private var toolbar: ScreenNotePanel?
    @ObservationIgnored private var canvases: [UInt32: ScreenInkView] = [:]
    @ObservationIgnored private var observations: [NotificationToken] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private weak var previousWindow: NSWindow?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var transcriptResult: TranscriptHandOff.Result?
    @ObservationIgnored private var finishRequested = false
    @ObservationIgnored private var warning: String?

    var isActive: Bool { phase != .idle }
    var isNarrating: Bool { isActive && phase != .drawing }
    var isDrawing: Bool { isActive && drawingEnabled }
    var canSnap: Bool { phase == .recording && !captureBusy && shotCount < ScreenNote.maximumShots }

    init(core: AppCore) { self.core = core }

    func apply() {
        core.appIndex.setCommandsVisible([.copyLastScreenNote, .copyLastScreenNoteText],
                                         settings.screenNotesEnabled && lastNote != nil)
        if !settings.screenNotesEnabled {
            stop()
            exportTask?.cancel()
        } else if isNarrating && !settings.dictationEnabled {
            stop()
        }
    }

    func toggle() {
        if isNarrating { toggleDrawing(); return }
        if isActive { stop(); return }
        guard settings.screenNotesEnabled, exportTask == nil, let screen = NSScreen.underCursor else { return }
        beginSession(on: screen, phase: .drawing)
        showPanels(on: NSScreen.screens, toolbarScreen: screen)
    }

    func explain(on screen: NSScreen? = nil) {
        if phase == .recording { finishNote(); return }
        guard phase == .idle || phase == .drawing else { return }
        guard exportTask == nil else { return }
        guard settings.screenNotesEnabled else { return }
        guard settings.dictationEnabled else {
            core.showMessage("Enable Dictation first.", tone: .neutral)
            return
        }
        if let issue = core.dictation.handOffUnavailableReason() {
            core.showMessage(issue, tone: .neutral)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if isActive { stop(restoreFocus: false) }
            _ = CGRequestScreenCaptureAccess()
            core.showMessage("Allow Screen Recording in System Settings, then try Explain Screen again.", tone: .neutral)
            return
        }
        guard let screen = screen ?? NSScreen.underCursor else { return }
        if isActive { stop(restoreFocus: false) }
        beginSession(on: screen, phase: .starting)
        guard let id = sessionID else { return }
        let directory = AppPaths.caches().appending(path: "ScreenNotes/\(id.uuidString)", directoryHint: .isDirectory)
        note = ScreenNote(id: id, directory: directory, displayName: screen.localizedName)
        snap()
    }

    private func beginSession(on screen: NSScreen, phase: Phase) {
        previousWindow = NSApp.keyWindow
        previousApp = NSWorkspace.shared.frontmostApplication
        self.phase = phase
        sessionID = UUID()
        targetScreen = screen
        displayName = screen.localizedName
        startedAt = CACurrentMediaTime()
        transcriptResult = nil
        warning = nil
        finishRequested = false
        shotCount = 0
        observe(NSApplication.didChangeScreenParametersNotification, center: .default)
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter)
        observe(NSWorkspace.sessionDidResignActiveNotification, center: NSWorkspace.shared.notificationCenter)
        if phase == .drawing {
            observe(NSWorkspace.activeSpaceDidChangeNotification, center: NSWorkspace.shared.notificationCenter)
            observe(NSWorkspace.didActivateApplicationNotification, center: NSWorkspace.shared.notificationCenter)
        }
    }

    private func beginNarration() {
        guard let id = sessionID, let targetScreen else { return }
        let start = core.dictation.beginHandOff(TranscriptHandOff(id: id, finish: { [weak self] result in
            guard let self, self.sessionID == id else { return }
            if case .cancelled = result { self.stop(restoreFocus: false); return }
            self.transcriptResult = result
            if self.phase == .recording { self.finishNote() }
            self.publishIfReady()
        }))
        switch start {
        case .started:
            phase = .recording
            showPanels(on: [targetScreen], toolbarScreen: targetScreen)
        case .unavailable(let message):
            stop()
            core.showMessage(message, tone: .neutral)
        }
    }

    func toggleDrawing() {
        guard phase == .recording || phase == .drawing else { return }
        setDrawing(!drawingEnabled)
    }

    private func setDrawing(_ enabled: Bool) {
        if enabled, !ownsKeyWindow {
            previousWindow = NSApp.keyWindow
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        drawingEnabled = enabled
        for panel in panels { panel.ignoresMouseEvents = !enabled }
        if enabled, let panel = panels.first(where: { $0.screen == targetScreen }) {
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        } else if !enabled, ownsKeyWindow {
            restoreFocus()
        }
    }

    func snap() {
        guard settings.screenNotesEnabled, settings.dictationEnabled,
              phase == .starting || phase == .recording || phase == .finishing,
              !captureBusy, let id = sessionID, let targetScreen,
              let displayID = Self.displayID(targetScreen), let note else { return }
        guard note.canAddShot else {
            if phase == .finishing { publishIfReady() }
            return
        }
        let now = CACurrentMediaTime()
        ink.prune(now: now)
        let strokes = ink.strokes.filter { $0.displayID == displayID }
            + (ink.active.map { [$0] } ?? [])
        let file = note.directory.appendingPathComponent(String(format: "Shot %02d.png", note.shots.count + 1))
        let elapsed = now - startedAt
        let excluded = panels.map(\.windowNumber) + [toolbar?.windowNumber].compactMap { $0 }
        captureBusy = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await ScreenNoteCapture.capture(
                    displayID: displayID, pointSize: targetScreen.frame.size, excludedWindows: excluded,
                    strokes: strokes, file: file)
                try Task.checkCancellation()
                guard sessionID == id else { return }
                if self.note?.append(ScreenNote.Shot(file: file, elapsed: elapsed, byteCount: bytes)) == true {
                    shotCount = self.note?.shots.count ?? 0
                    ink.remove(ids: Set(strokes.map(\.id)))
                    sync()
                } else {
                    try FileManager.default.removeItem(at: file)
                    warning = "The screenshot size limit was reached."
                    core.showMessage("Screen note size limit reached. Finish this note first.", tone: .neutral)
                }
            } catch {
                guard !Task.isCancelled, sessionID == id else { return }
                if phase == .starting {
                    stop()
                    core.showMessage(error.localizedDescription, tone: .danger)
                    return
                }
                warning = "The last screenshot could not be captured."
                core.showMessage(error.localizedDescription, tone: .danger)
            }
            captureBusy = false
            captureTask = nil
            if phase == .starting {
                beginNarration()
            } else if finishRequested, phase == .recording {
                finishNote()
            }
            publishIfReady()
        }
    }

    func finishNote() {
        guard phase == .recording, let id = sessionID else { return }
        if captureBusy { finishRequested = true; return }
        phase = .finishing
        finishRequested = false
        setDrawing(false)
        toolbar?.orderOut(nil)
        core.showProgress("Transcribing…", onCancel: { [weak self] in self?.stop() })
        core.dictation.endHandOff(id: id)
        snap()
        publishIfReady()
    }

    private func publishIfReady() {
        guard phase == .finishing, !captureBusy, let result = transcriptResult, var prepared = note else { return }
        switch result {
        case .transcript(let text, let issue): prepared.transcript = text; warning = issue ?? warning
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
                guard sessionID == completed.id, settings.screenNotesEnabled, settings.dictationEnabled else { return }
                guard ScreenNoteClipboard.write(payload, to: .general) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                lastNote = completed
                apply()
                let message = completed.transcript.isEmpty
                    ? "Copied \(completed.shots.count) screenshots; no speech captured."
                    : "Copied \(completed.shots.count) screenshots and note."
                let issue = warning
                stop()
                core.showMessage(issue == nil ? message : message + " Speech or capture may be incomplete.",
                                 tone: issue == nil ? .success : .neutral)
                pruneOutputs(keeping: completed.directory)
            } catch {
                guard !Task.isCancelled, sessionID == completed.id else { return }
                lastNote = completed
                apply()
                stop()
                core.showMessage("Could not copy the screen note. Use Copy Last Screen Note to retry.", tone: .danger)
            }
        }
    }

    func copyLastNote(textOnly: Bool = false) {
        guard settings.screenNotesEnabled, !isActive, exportTask == nil, let lastNote else { return }
        if textOnly {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lastNote.text, forType: .string)
            core.showMessage("Copied note text.")
            return
        }
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { exportTask = nil }
            do {
                let payload = try await Task.detached { try ScreenNoteClipboard.prepare(lastNote) }.value
                try Task.checkCancellation()
                guard settings.screenNotesEnabled else { return }
                guard ScreenNoteClipboard.write(payload, to: .general) else { throw CocoaError(.fileWriteUnknown) }
                core.showMessage("Copied screenshots and note.")
            } catch {
                guard !Task.isCancelled else { return }
                core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    func stop(restoreFocus shouldRestore: Bool = true) {
        guard isActive else { return }
        let id = sessionID
        let directory = note?.directory
        let shouldRestore = shouldRestore && ownsKeyWindow
        let hadProgress = phase == .finishing || phase == .copying
        phase = .idle
        sessionID = nil
        if let id { core.dictation.cancelHandOff(id: id) }
        let pendingCapture = captureTask
        let pendingExport = exportTask
        captureTask?.cancel()
        exportTask?.cancel()
        expiryTask?.cancel()
        captureTask = nil
        exportTask = nil
        expiryTask = nil
        observations.removeAll()
        for panel in panels { panel.orderOut(nil); panel.contentView = nil }
        toolbar?.orderOut(nil)
        toolbar?.contentView = nil
        toolbar = nil
        panels.removeAll()
        canvases.removeAll()
        ink.clear()
        note = nil
        drawingEnabled = false
        canUndo = false
        captureBusy = false
        if hadProgress { core.hideProgress() }
        if shouldRestore { restoreFocus() }
        previousWindow = nil
        previousApp = nil
        targetScreen = nil
        if let directory, directory != lastNote?.directory {
            remove(directory, after: pendingCapture, export: pendingExport)
        }
    }

    func prepareForTermination() async {
        stop(restoreFocus: false)
        exportTask?.cancel()
        await exportTask?.value
        await cleanupTask?.value
    }

    private func remove(_ directory: URL, after capture: Task<Void, Never>? = nil, export: Task<Void, Never>? = nil) {
        let previous = cleanupTask
        cleanupTask = Task {
            await previous?.value
            await capture?.value
            await export?.value
            _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
        }
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
            let publishedDirectory = self?.lastNote?.directory
            let stale = entries.filter {
                $0 != directory && $0 != activeDirectory && $0 != publishedDirectory
                    && UUID(uuidString: $0.lastPathComponent) != nil
            }
            _ = await Task.detached(priority: .utility) {
                for entry in stale { try? FileManager.default.removeItem(at: entry) }
            }.value
        }
    }

    private func restoreFocus() {
        if let previousWindow, previousWindow.isVisible {
            previousWindow.makeKeyAndOrderFront(nil)
        } else {
            previousApp?.activate()
        }
    }

    private var ownsKeyWindow: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key === toolbar || panels.contains { $0 === key }
    }

    func begin(at point: CGPoint, displayID: UInt32, arrow: Bool) {
        guard isDrawing else { return }
        ink.begin(at: point, displayID: displayID, tool: arrow ? .arrow : settings.screenNotesTool,
                  color: settings.screenNotesColor, width: settings.screenNotesWidth)
        syncActive()
        canUndo = true
    }

    func append(_ point: CGPoint) {
        ink.append(point)
        if let stroke = ink.active { canvases[stroke.displayID]?.showActive(stroke) }
    }

    func finish() {
        ink.finish(now: CACurrentMediaTime(), lifetime: isNarrating ? .manual : settings.screenNotesLifetime)
        sync()
    }

    func undo() { ink.undo(now: CACurrentMediaTime()); sync() }
    func clear() { ink.clear(); sync() }

    func handleKey(_ key: String) {
        if key == " ", isNarrating { snap(); return }
        if key == "d" { toggleDrawing(); return }
        if let index = Int(key), (1...ScreenInk.Color.allCases.count).contains(index) {
            settings.screenNotesColor = ScreenInk.Color.allCases[index - 1]
        } else if key == "p" {
            settings.screenNotesTool = .pen
        } else if key == "a" {
            settings.screenNotesTool = .arrow
        } else if key == "[" || key == "]" {
            let widths = ScreenInk.Width.allCases
            let index = widths.firstIndex(of: settings.screenNotesWidth) ?? 1
            settings.screenNotesWidth = widths[min(widths.count - 1, max(0, index + (key == "]" ? 1 : -1)))]
        }
    }

    private func syncActive() { for canvas in canvases.values { canvas.showActive(ink.active) } }

    private func sync() {
        let now = CACurrentMediaTime()
        ink.prune(now: now)
        syncActive()
        for canvas in canvases.values { canvas.sync(ink.strokes, now: now) }
        canUndo = ink.active != nil || !ink.strokes.isEmpty
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiry = ink.nextExpiry else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry - now))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private func showPanels(on screens: [NSScreen], toolbarScreen: NSScreen) {
        for screen in screens {
            guard let displayID = Self.displayID(screen) else { continue }
            let panel = ScreenNotePanel(screen: screen, coordinator: self)
            let canvas = ScreenInkView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       displayID: displayID, coordinator: self)
            panel.contentView = canvas
            canvases[displayID] = canvas
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        let panel = ScreenNotePanel(screen: toolbarScreen, coordinator: self)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let host = NSHostingView(rootView: ScreenNoteToolbar().environment(self).environment(settings))
        host.sizingOptions = []
        panel.contentView = host
        let size = isNarrating ? Theme.Size.screenNoteCaptureToolbar : Theme.Size.screenNotesToolbar
        panel.setFrame(NSRect(x: toolbarScreen.visibleFrame.midX - size.width / 2,
                              y: toolbarScreen.visibleFrame.maxY - size.height - Theme.Spacing.xl,
                              width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        toolbar = panel
        setDrawing(true)
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let session = sessionID
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == session else { return }
                self.stop(restoreFocus: false)
            }
        }
        observations.append(NotificationToken(token, center: center))
    }
}
