import SwiftUI

/// Delay before a closed palette pops to root; an unset key reads as `.immediately`.
enum PopToRootTimeout: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case afterFive = 5
    case afterFifteen = 15
    case afterThirty = 30
    case afterSixty = 60
    case afterNinety = 90

    var id: Int { rawValue }

    var title: String {
        self == .immediately ? "Immediately" : "After \(rawValue) seconds"
    }

    var interval: TimeInterval { TimeInterval(rawValue) }
}

/// How early the join card appears, and how long past the start it stays. See UpcomingWindow.
enum JoinWindow: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case fifteen = 15

    var id: Int { rawValue }

    var title: String { rawValue == 1 ? "1 minute" : "\(rawValue) minutes" }
}

/// How early the calendar item picks the next event up. Zero, which `integer(forKey:)` also
/// returns unset, keeps it for the rest of today.
enum MenuBarEvents: Int, CaseIterable, Identifiable, Sendable {
    case today = 0
    case two = 2
    case five = 5
    case ten = 10
    case thirty = 30

    var id: Int { rawValue }

    var title: String { self == .today ? "Today" : "\(rawValue) minutes before" }
}

/// The calendar's independent menu-bar presence. Zero matches an unset preference.
enum CalendarMenuBarDisplay: Int, CaseIterable, Identifiable, Sendable {
    case disabled = 0
    case meetingIcon = 1
    case meetingTitle = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .meetingIcon: "Meeting Icon"
        case .meetingTitle: "Meeting Title"
        }
    }
}

/// How long a started event holds the menu bar. Zero, the default, means it goes as it starts.
enum CalendarLauncherLimit: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case three = 3
    case five = 5
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .one: "1 next"
        case .three: "3 next"
        case .five: "5 next"
        case .all: "All"
        }
    }

    var maximum: Int? { self == .all ? nil : rawValue }
}

/// Whether a started event remains in the menu bar long enough to show its time left.
enum HideCurrentEvent: Int, CaseIterable, Identifiable, Sendable {
    case dontHide = -1
    case automatically = 0
    case afterFive = 5
    case afterTen = 10
    case afterThirty = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .dontHide: "Keep visible — show time left"
        case .automatically: "Automatically"
        default: "After \(rawValue) minutes"
        }
    }

    var hidesAtStart: Bool { self == .automatically }
    var minutes: Int? { rawValue > 0 ? rawValue : nil }
}

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    private typealias Key = AppSettingsKey

    /// What `AppIndex` scans, in scan order; editing it re-indexes, being observed.
    var searchScopes: [String] {
        didSet { defaults.set(searchScopes, forKey: Key.searchScopes.rawValue) }
    }

    /// How loose a fuzzy root-search hit may be and still show.
    var rootSearchSensitivity: SearchSensitivity {
        didSet {
            defaults.set(rootSearchSensitivity.rawValue, forKey: Key.rootSearchSensitivity.rawValue)
        }
    }

    var launchAtLogin: Bool {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    /// The launcher icon's visibility; dragging the icon out of the menu bar turns it off.
    var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar.rawValue) }
    }

    var automaticallyCheckForUpdates: Bool {
        didSet {
            defaults.set(
                automaticallyCheckForUpdates, forKey: Key.automaticallyCheckForUpdates.rawValue)
        }
    }

    /// Preferred skin tone applied to modifier-capable emoji at render and copy time.
    var emojiSkinTone: EmojiSkinTone {
        didSet { defaults.set(emojiSkinTone.rawValue, forKey: Key.emojiSkinTone.rawValue) }
    }

    /// Grid density used when the emoji picker opens; in-session zoom remains temporary.
    var emojiGridColumns: EmojiGridColumns {
        didSet { defaults.set(emojiGridColumns.rawValue, forKey: Key.emojiGridColumns.rawValue) }
    }

    /// How long a closed palette keeps its state before popping back to the root launcher.
    var popToRootTimeout: PopToRootTimeout {
        didSet { defaults.set(popToRootTimeout.rawValue, forKey: Key.popToRootTimeout.rawValue) }
    }

    /// Whether Escape walks back through the screens the palette opened, or just closes it.
    var escapeKeyBehavior: EscapeKeyBehavior {
        didSet { defaults.set(escapeKeyBehavior.rawValue, forKey: Key.escapeKeyBehavior.rawValue) }
    }

    /// Follow macOS, or pin Ollie to one appearance. Applied by `AppCore.applyAppearance()`.
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance.rawValue) }
    }

    /// Which separators the calculator reads and writes; `.system` follows Language & Region.
    var calcNumberStyle: CalcNumberStyle {
        didSet { defaults.set(calcNumberStyle.rawValue, forKey: Key.calcNumberStyle.rawValue) }
    }

    /// Scales the palette and its floating siblings only. Read through `InterfaceSize.metrics`.
    var paletteDensity: PaletteDensity {
        didSet { defaults.set(paletteDensity.rawValue, forKey: Key.paletteDensity.rawValue) }
    }

    var interfaceSize: InterfaceSize {
        didSet {
            defaults.set(interfaceSize.rawValue, forKey: Key.interfaceSize.rawValue)
            let shift = Double(
                (oldValue.metrics.size.panelWidth - interfaceSize.metrics.size.panelWidth) / 2)
            if shift != 0 {
                palettePositions = palettePositions.mapValues { offset in
                    offset.count == 2 ? [offset[0] + shift, offset[1]] : offset
                }
            }
        }
    }

    /// Summon the launcher as just its search bar, revealing results on typing or ↓.
    var compactMode: Bool {
        didSet { defaults.set(compactMode, forKey: Key.compactMode.rawValue) }
    }

    /// Summon the palette on the display under the pointer instead of the one holding the menu bar.
    var openOnCursorScreen: Bool {
        didSet { defaults.set(openOnCursorScreen, forKey: Key.openOnCursorScreen.rawValue) }
    }

    var autoSwitchInputSourceID: String? {
        didSet {
            guard let autoSwitchInputSourceID else {
                defaults.removeObject(forKey: Key.autoSwitchInputSource.rawValue)
                return
            }
            defaults.set(autoSwitchInputSourceID, forKey: Key.autoSwitchInputSource.rawValue)
        }
    }

    /// Lets the panel be dragged by its top edge; off by default, so most launches never grab it.
    var paletteDraggable: Bool {
        didSet { defaults.set(paletteDraggable, forKey: Key.paletteDraggable.rawValue) }
    }

    /// Where a drag left the panel's top-left, per display and relative to it.
    var palettePositions: [String: [Double]] {
        didSet { defaults.set(palettePositions, forKey: Key.palettePosition.rawValue) }
    }

    var paletteExpandedCenterDisplays: Set<String> {
        didSet {
            defaults.set(
                Array(paletteExpandedCenterDisplays),
                forKey: Key.paletteExpandedCenterDisplays.rawValue)
        }
    }

    func palettePosition(on display: String) -> CGPoint? {
        palettePositions[display].flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    func setPalettePosition(_ offset: CGPoint?, on display: String, expandedCenter: Bool) {
        if offset != nil && expandedCenter {
            paletteExpandedCenterDisplays.insert(display)
        } else {
            paletteExpandedCenterDisplays.remove(display)
        }
        guard let offset else {
            palettePositions.removeValue(forKey: display)
            return
        }
        palettePositions[display] = [offset.x, offset.y]
    }

    // Feature switches, off out of the box, and off means fully off.
    var fileSearchEnabled: Bool {
        didSet { defaults.set(fileSearchEnabled, forKey: Key.fileSearchEnabled.rawValue) }
    }

    /// Tilde-abbreviated, so a backup taken on one machine still points somewhere on another.
    var fileSearchScopes: [String] {
        didSet { defaults.set(fileSearchScopes, forKey: Key.fileSearchScopes.rawValue) }
    }

    /// Only what the user added; the shipped rules are compiled into `FileSearchIgnoreList`.
    var fileSearchIgnorePatterns: [String] {
        didSet {
            defaults.set(fileSearchIgnorePatterns, forKey: Key.fileSearchIgnorePatterns.rawValue)
        }
    }

    var notesEnabled: Bool {
        didSet { defaults.set(notesEnabled, forKey: Key.notesEnabled.rawValue) }
    }

    var notesRendersMarkdown: Bool {
        didSet { defaults.set(notesRendersMarkdown, forKey: Key.notesRendersMarkdown.rawValue) }
    }

    var notesShowsFormattingBar: Bool {
        didSet { defaults.set(notesShowsFormattingBar, forKey: Key.notesShowsFormattingBar.rawValue) }
    }

    /// The notes folder as the user wrote it, `~` allowed; nil keeps it in Application Support.
    var notesFolder: String? {
        didSet { defaults.set(notesFolder, forKey: Key.notesFolder.rawValue) }
    }

    /// Off by default: connecting a server is consent to run code Ollie did not write.
    var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: Key.mcpEnabled.rawValue) }
    }
    var aiEnabled: Bool {
        didSet { defaults.set(aiEnabled, forKey: Key.aiEnabled.rawValue) }
    }

    var customCommandsEnabled: Bool {
        didSet { defaults.set(customCommandsEnabled, forKey: Key.customCommandsEnabled.rawValue) }
    }

    /// With the feature on, controls only whether its launcher section appears.
    var customCommandsShowInLauncher: Bool {
        didSet {
            defaults.set(
                customCommandsShowInLauncher, forKey: Key.customCommandsShowInLauncher.rawValue)
        }
    }

    /// Off out of the box: on means Ollie may read a selection anywhere and type over it.
    var quickActionsEnabled: Bool {
        didSet { defaults.set(quickActionsEnabled, forKey: Key.quickActionsEnabled.rawValue) }
    }

    var navigationEnabled: Bool {
        didSet { defaults.set(navigationEnabled, forKey: Key.navigationEnabled.rawValue) }
    }

    /// Bundle IDs whose menu bar Search Menu Bar Items refuses to read at all.
    var menuSearchDisabledApps: [String] {
        didSet { defaults.set(menuSearchDisabledApps, forKey: Key.menuSearchDisabledApps.rawValue) }
    }

    /// Off: the Apple menu is the same on every app, so it would only pad every snapshot.
    var menuSearchShowsAppleMenu: Bool {
        didSet {
            defaults.set(menuSearchShowsAppleMenu, forKey: Key.menuSearchShowsAppleMenu.rawValue)
        }
    }

    /// Consent to run third-party JavaScript: it confirms, defaults off, rides no backup.
    var extensionsEnabled: Bool {
        didSet { defaults.set(extensionsEnabled, forKey: Key.extensionsEnabled.rawValue) }
    }

    var extensionsShowInLauncher: Bool {
        didSet {
            defaults.set(extensionsShowInLauncher, forKey: Key.extensionsShowInLauncher.rawValue)
        }
    }

    /// Only an install from GitHub needs one — the store serves extensions already built.
    var extensionPackageManager: ExtensionPackageManager {
        didSet {
            defaults.set(
                extensionPackageManager.rawValue, forKey: Key.extensionPackageManager.rawValue)
        }
    }

    /// For a toolchain Ollie doesn't know — mise or Nix shims are the common case.
    var extensionCustomSearchPaths: [String] {
        didSet {
            defaults.set(
                extensionCustomSearchPaths, forKey: Key.extensionCustomSearchPaths.rawValue)
        }
    }

    /// Doubles as calendar-access consent, so only `CalendarCoordinator` may write it.
    var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: Key.calendarEnabled.rawValue) }
    }

    var calendarShowInLauncher: Bool {
        didSet {
            defaults.set(calendarShowInLauncher, forKey: Key.calendarShowInLauncher.rawValue)
        }
    }

    var calendarLauncherLimit: CalendarLauncherLimit {
        didSet {
            defaults.set(calendarLauncherLimit.rawValue, forKey: Key.calendarLauncherLimit.rawValue)
        }
    }

    /// Narrows the fetch itself rather than what is shown, so every surface reads the same days.
    var calendarSpan: MeetingSpan {
        didSet { defaults.set(calendarSpan.rawValue, forKey: Key.calendarSpan.rawValue) }
    }

    var joinWindowMinutes: JoinWindow {
        didSet { defaults.set(joinWindowMinutes.rawValue, forKey: Key.joinWindowMinutes.rawValue) }
    }

    /// Arms the app to open meeting links unattended, so only the Calendar pane's switch writes it.
    var autoJoinMeetings: Bool {
        didSet { defaults.set(autoJoinMeetings, forKey: Key.autoJoinMeetings.rawValue) }
    }

    var autoJoinConfirms: Bool {
        didSet { defaults.set(autoJoinConfirms, forKey: Key.autoJoinConfirms.rawValue) }
    }

    var autoJoinNamedProvidersOnly: Bool {
        didSet {
            defaults.set(
                autoJoinNamedProvidersOnly, forKey: Key.autoJoinNamedProvidersOnly.rawValue)
        }
    }

    /// Doubles as camera consent, so only the Calendar pane's switch writes it.
    var cameraPreview: Bool {
        didSet { defaults.set(cameraPreview, forKey: Key.cameraPreview.rawValue) }
    }

    /// Nil opens meeting links in the default browser.
    var meetingBrowserBundleID: String? {
        didSet {
            guard let meetingBrowserBundleID else {
                defaults.removeObject(forKey: Key.meetingBrowser.rawValue)
                return
            }
            defaults.set(meetingBrowserBundleID, forKey: Key.meetingBrowser.rawValue)
        }
    }

    var menuBarEvents: MenuBarEvents {
        didSet { defaults.set(menuBarEvents.rawValue, forKey: Key.menuBarEvents.rawValue) }
    }

    var calendarMenuBarDisplay: CalendarMenuBarDisplay {
        didSet {
            defaults.set(
                calendarMenuBarDisplay.rawValue, forKey: Key.calendarMenuBarDisplay.rawValue)
        }
    }

    var menuBarLinkedEventsOnly: Bool {
        didSet {
            defaults.set(
                menuBarLinkedEventsOnly, forKey: Key.menuBarLinkedEventsOnly.rawValue)
        }
    }

    var calendarMenuBarHidesWhenEmpty: Bool {
        didSet {
            defaults.set(
                calendarMenuBarHidesWhenEmpty, forKey: Key.calendarMenuBarHidesWhenEmpty.rawValue)
        }
    }

    var hideCurrentEvent: HideCurrentEvent {
        didSet { defaults.set(hideCurrentEvent.rawValue, forKey: Key.hideCurrentEvent.rawValue) }
    }

    /// Off means fully off: no launcher entries, and a still-registered shortcut moves nothing.
    var windowManagementEnabled: Bool {
        didSet {
            defaults.set(windowManagementEnabled, forKey: Key.windowManagementEnabled.rawValue)
        }
    }

    var windowManagementShowInLauncher: Bool {
        didSet {
            defaults.set(
                windowManagementShowInLauncher,
                forKey: Key.windowManagementShowInLauncher.rawValue)
        }
    }

    /// Points between tiled windows and the screen edge; `WindowPlacementEngine` caps it.
    var windowGap: Int {
        didSet { defaults.set(windowGap, forKey: Key.windowGap.rawValue) }
    }

    /// Its own flag: hiding 34 command rows must not also hide the layouts you wrote.
    var windowLayoutsShowInLauncher: Bool {
        didSet {
            defaults.set(
                windowLayoutsShowInLauncher, forKey: Key.windowLayoutsShowInLauncher.rawValue)
        }
    }

    var windowRoomsShowInLauncher: Bool {
        didSet {
            defaults.set(windowRoomsShowInLauncher, forKey: Key.windowRoomsShowInLauncher.rawValue)
        }
    }

    /// What re-triggering a half does: nothing, step its size, or walk it across the displays.
    var windowCycle: WindowCycle {
        didSet { defaults.set(windowCycle.rawValue, forKey: Key.windowCycle.rawValue) }
    }

    /// Off means fully off, down to a still-registered shortcut opening nothing.
    var quicklinksEnabled: Bool {
        didSet { defaults.set(quicklinksEnabled, forKey: Key.quicklinksEnabled.rawValue) }
    }

    var quicklinksShowInLauncher: Bool {
        didSet {
            defaults.set(quicklinksShowInLauncher, forKey: Key.quicklinksShowInLauncher.rawValue)
        }
    }

    /// Off means the Shortcuts tool is never run, down to a bound shortcut running nothing.
    var appleShortcutsEnabled: Bool {
        didSet { defaults.set(appleShortcutsEnabled, forKey: Key.appleShortcutsEnabled.rawValue) }
    }

    /// Ask for a new window rather than a tab; off is the macOS default.
    var quicklinkOpensNewWindow: Bool {
        didSet {
            defaults.set(quicklinkOpensNewWindow, forKey: Key.quicklinkOpensNewWindow.rawValue)
        }
    }

    /// What `{selection}` does when there is no readable selection to pass.
    var quicklinkSelectionFallback: QuicklinkSelectionFallback {
        didSet {
            defaults.set(
                quicklinkSelectionFallback.rawValue,
                forKey: Key.quicklinkSelectionFallback.rawValue)
        }
    }

    var quicklinkConfirmsBeforeDelete: Bool {
        didSet {
            defaults.set(
                quicklinkConfirmsBeforeDelete, forKey: Key.quicklinkConfirmsBeforeDelete.rawValue)
        }
    }

    /// Whether the support window may reopen itself; off means never ask again.
    var supportRemindersEnabled: Bool {
        didSet { defaults.set(supportRemindersEnabled, forKey: Key.supportReminders.rawValue) }
    }

    /// Whether settings.json mirrors these settings; `AppCore` starts and stops the mirror.
    var settingsFileEnabled: Bool {
        didSet { defaults.set(settingsFileEnabled, forKey: Key.settingsFileEnabled.rawValue) }
    }

    var dictationEnabled: Bool {
        didSet { defaults.set(dictationEnabled, forKey: Key.dictationEnabled.rawValue) }
    }
    var spacesEnabled: Bool {
        didSet { defaults.set(spacesEnabled, forKey: Key.spacesEnabled.rawValue) }
    }
    var spacesTransitionSpeed: String {
        didSet { defaults.set(spacesTransitionSpeed, forKey: Key.spacesTransitionSpeed.rawValue) }
    }

    var windowSwitcherEnabled: Bool {
        didSet { defaults.set(windowSwitcherEnabled, forKey: Key.windowSwitcherEnabled.rawValue) }
    }
    var switcherCommandTab: Bool {
        didSet { defaults.set(switcherCommandTab, forKey: Key.switcherCommandTab.rawValue) }
    }
    var switcherCommandBacktick: Bool {
        didSet { defaults.set(switcherCommandBacktick, forKey: Key.switcherCommandBacktick.rawValue) }
    }
    var switcherWindowSource: String {
        didSet { defaults.set(switcherWindowSource, forKey: Key.switcherWindowSource.rawValue) }
    }
    var switcherMinimizedMode: String {
        didSet { defaults.set(switcherMinimizedMode, forKey: Key.switcherMinimizedMode.rawValue) }
    }
    var switcherHiddenMode: String {
        didSet { defaults.set(switcherHiddenMode, forKey: Key.switcherHiddenMode.rawValue) }
    }
    var switcherAppsWithoutWindowsMode: String {
        didSet { defaults.set(switcherAppsWithoutWindowsMode, forKey: Key.switcherAppsWithoutWindowsMode.rawValue) }
    }
    var switcherImmediatePreview: Bool {
        didSet { defaults.set(switcherImmediatePreview, forKey: Key.switcherImmediatePreview.rawValue) }
    }
    var diagnosticsEnabled: Bool {
        didSet { defaults.set(diagnosticsEnabled, forKey: Key.diagnosticsEnabled.rawValue) }
    }

    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled.rawValue) }
    }
    var snippetsEnabled: Bool {
        didSet { defaults.set(snippetsEnabled, forKey: Key.snippetsEnabled.rawValue) }
    }
    var clipboardHistoryDays: Int {
        didSet { defaults.set(clipboardHistoryDays, forKey: Key.clipboardHistoryDays.rawValue) }
    }

    var launcherEnabled: Bool {
        didSet { defaults.set(launcherEnabled, forKey: Key.launcherEnabled.rawValue) }
    }

    var mediaImportEnabled: Bool {
        didSet { defaults.set(mediaImportEnabled, forKey: Key.mediaImportEnabled.rawValue) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled.rawValue) }
    }

    var networkEnabled: Bool {
        didSet { defaults.set(networkEnabled, forKey: Key.networkEnabled.rawValue) }
    }

    var screenNotesEnabled: Bool {
        didSet { defaults.set(screenNotesEnabled, forKey: Key.screenNotesEnabled.rawValue) }
    }

    var typingSoundsEnabled: Bool {
        didSet { defaults.set(typingSoundsEnabled, forKey: Key.typingSoundsEnabled.rawValue) }
    }

    var typingSoundProfile: String {
        didSet { defaults.set(typingSoundProfile, forKey: Key.typingSoundProfile.rawValue) }
    }

    var typingSoundVolume: Int {
        didSet { defaults.set(typingSoundVolume, forKey: Key.typingSoundVolume.rawValue) }
    }

    var typingSoundDownVolume: Int {
        didSet { defaults.set(typingSoundDownVolume, forKey: Key.typingSoundDownVolume.rawValue) }
    }

    var typingSoundUpVolume: Int {
        didSet { defaults.set(typingSoundUpVolume, forKey: Key.typingSoundUpVolume.rawValue) }
    }

    var typingMouseEnabled: Bool {
        didSet { defaults.set(typingMouseEnabled, forKey: Key.typingMouseEnabled.rawValue) }
    }

    var typingMouseVolume: Int {
        didSet { defaults.set(typingMouseVolume, forKey: Key.typingMouseVolume.rawValue) }
    }

    init() {
        dictationEnabled = defaults.bool(forKey: Key.dictationEnabled.rawValue)
        spacesEnabled = defaults.bool(forKey: Key.spacesEnabled.rawValue)
        spacesTransitionSpeed = defaults.string(forKey: Key.spacesTransitionSpeed.rawValue) ?? "instant"
        windowSwitcherEnabled = defaults.object(forKey: Key.windowSwitcherEnabled.rawValue) == nil ? false : defaults.bool(forKey: Key.windowSwitcherEnabled.rawValue)
        switcherCommandTab = defaults.object(forKey: Key.switcherCommandTab.rawValue) == nil ? true : defaults.bool(forKey: Key.switcherCommandTab.rawValue)
        switcherCommandBacktick = defaults.object(forKey: Key.switcherCommandBacktick.rawValue) == nil ? true : defaults.bool(forKey: Key.switcherCommandBacktick.rawValue)
        switcherWindowSource = defaults.string(forKey: Key.switcherWindowSource.rawValue) ?? "allSpaces"
        switcherMinimizedMode = defaults.string(forKey: Key.switcherMinimizedMode.rawValue) ?? "doNotShow"
        switcherHiddenMode = defaults.string(forKey: Key.switcherHiddenMode.rawValue) ?? "doNotShow"
        switcherAppsWithoutWindowsMode = defaults.string(forKey: Key.switcherAppsWithoutWindowsMode.rawValue) ?? "showAtBottom"
        switcherImmediatePreview = defaults.object(forKey: Key.switcherImmediatePreview.rawValue) == nil ? false : defaults.bool(forKey: Key.switcherImmediatePreview.rawValue)
        diagnosticsEnabled = defaults.object(forKey: Key.diagnosticsEnabled.rawValue) == nil ? false : defaults.bool(forKey: Key.diagnosticsEnabled.rawValue)
        clipboardEnabled = defaults.bool(forKey: Key.clipboardEnabled.rawValue)
        snippetsEnabled = defaults.bool(forKey: Key.snippetsEnabled.rawValue)
        let savedHistoryDays = defaults.integer(forKey: Key.clipboardHistoryDays.rawValue)
        clipboardHistoryDays = [1, 7, 30, 180].contains(savedHistoryDays) ? savedHistoryDays : 7
        launcherEnabled = defaults.object(forKey: Key.launcherEnabled.rawValue) == nil
            || defaults.bool(forKey: Key.launcherEnabled.rawValue)
        mediaImportEnabled = defaults.bool(forKey: Key.mediaImportEnabled.rawValue)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled.rawValue)
        networkEnabled = defaults.bool(forKey: Key.networkEnabled.rawValue)
        screenNotesEnabled = defaults.bool(forKey: Key.screenNotesEnabled.rawValue)
        typingSoundsEnabled = defaults.object(forKey: Key.typingSoundsEnabled.rawValue) == nil ? false
            : defaults.bool(forKey: Key.typingSoundsEnabled.rawValue)
        typingSoundProfile = defaults.object(forKey: Key.typingSoundProfile.rawValue) == nil ? "creamyLinear"
            : defaults.string(forKey: Key.typingSoundProfile.rawValue) ?? "creamyLinear"
        typingSoundVolume = defaults.object(forKey: Key.typingSoundVolume.rawValue) == nil ? 65
            : defaults.integer(forKey: Key.typingSoundVolume.rawValue)
        typingSoundDownVolume = defaults.object(forKey: Key.typingSoundDownVolume.rawValue) == nil ? 100
            : defaults.integer(forKey: Key.typingSoundDownVolume.rawValue)
        typingSoundUpVolume = defaults.object(forKey: Key.typingSoundUpVolume.rawValue) == nil ? 32
            : defaults.integer(forKey: Key.typingSoundUpVolume.rawValue)
        typingMouseEnabled = defaults.object(forKey: Key.typingMouseEnabled.rawValue) == nil ? false
            : defaults.bool(forKey: Key.typingMouseEnabled.rawValue)
        typingMouseVolume = defaults.object(forKey: Key.typingMouseVolume.rawValue) == nil ? 45
            : defaults.integer(forKey: Key.typingMouseVolume.rawValue)
        launchAtLogin = LaunchAtLogin.isEnabled
        showInMenuBar =
            defaults.object(forKey: Key.showInMenuBar.rawValue) == nil
            || defaults.bool(forKey: Key.showInMenuBar.rawValue)
        automaticallyCheckForUpdates =
            defaults.object(forKey: Key.automaticallyCheckForUpdates.rawValue) == nil
            || defaults.bool(forKey: Key.automaticallyCheckForUpdates.rawValue)
        emojiSkinTone =
            defaults.string(forKey: Key.emojiSkinTone.rawValue).flatMap(EmojiSkinTone.init) ?? .none
        emojiGridColumns =
            EmojiGridColumns(rawValue: defaults.integer(forKey: Key.emojiGridColumns.rawValue))
            ?? .default
        popToRootTimeout =
            PopToRootTimeout(rawValue: defaults.integer(forKey: Key.popToRootTimeout.rawValue))
            ?? .immediately
        escapeKeyBehavior =
            defaults.string(forKey: Key.escapeKeyBehavior.rawValue).flatMap(EscapeKeyBehavior.init)
            ?? .navigateBackOrClose
        appearance =
            defaults.string(forKey: Key.appearance.rawValue).flatMap(AppAppearance.init) ?? .system
        calcNumberStyle =
            defaults.string(forKey: Key.calcNumberStyle.rawValue).flatMap(CalcNumberStyle.init)
            ?? .system
        paletteDensity = defaults.string(forKey: Key.paletteDensity.rawValue).flatMap(PaletteDensity.init) ?? .compact
        interfaceSize =
            defaults.string(forKey: Key.interfaceSize.rawValue).flatMap(InterfaceSize.init)
            ?? .standard
        compactMode = defaults.bool(forKey: Key.compactMode.rawValue)

        // Unset seeds the defaults; a stored empty array is a deliberately cleared list.
        searchScopes =
            defaults.stringArray(forKey: Key.searchScopes.rawValue) ?? SearchScopes.defaults
        rootSearchSensitivity =
            defaults.string(forKey: Key.rootSearchSensitivity.rawValue)
            .flatMap(SearchSensitivity.init) ?? .default
        openOnCursorScreen =
            defaults.object(forKey: Key.openOnCursorScreen.rawValue) == nil
            || defaults.bool(forKey: Key.openOnCursorScreen.rawValue)
        autoSwitchInputSourceID = defaults.string(forKey: Key.autoSwitchInputSource.rawValue)
        paletteDraggable = defaults.bool(forKey: Key.paletteDraggable.rawValue)
        palettePositions =
            defaults.dictionary(forKey: Key.palettePosition.rawValue)
            as? [String: [Double]] ?? [:]
        paletteExpandedCenterDisplays =
            Set(defaults.stringArray(forKey: Key.paletteExpandedCenterDisplays.rawValue) ?? [])
        fileSearchEnabled = defaults.bool(forKey: Key.fileSearchEnabled.rawValue)
        // Unset seeds home; a stored empty array is a cleared list that searches nothing.
        fileSearchScopes =
            defaults.stringArray(forKey: Key.fileSearchScopes.rawValue)
            ?? FileSearchScope.defaultScopes
        fileSearchIgnorePatterns =
            defaults.stringArray(forKey: Key.fileSearchIgnorePatterns.rawValue) ?? []
        notesEnabled = defaults.bool(forKey: Key.notesEnabled.rawValue)
        notesRendersMarkdown =
            defaults.object(forKey: Key.notesRendersMarkdown.rawValue) == nil
            || defaults.bool(forKey: Key.notesRendersMarkdown.rawValue)
        notesShowsFormattingBar =
            defaults.object(forKey: Key.notesShowsFormattingBar.rawValue) == nil
            || defaults.bool(forKey: Key.notesShowsFormattingBar.rawValue)
        notesFolder = defaults.string(forKey: Key.notesFolder.rawValue)
        aiEnabled = defaults.bool(forKey: Key.aiEnabled.rawValue)
        mcpEnabled = defaults.bool(forKey: Key.mcpEnabled.rawValue)
        customCommandsEnabled = defaults.bool(forKey: Key.customCommandsEnabled.rawValue)
        // These default on, so absence must be distinguished from a stored `false`.
        customCommandsShowInLauncher =
            defaults.object(forKey: Key.customCommandsShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.customCommandsShowInLauncher.rawValue)
        quickActionsEnabled = defaults.bool(forKey: Key.quickActionsEnabled.rawValue)
        // Opt-in, unlike its siblings: until it is asked for, nothing about extensions is loaded.
        extensionsEnabled = defaults.bool(forKey: Key.extensionsEnabled.rawValue)
        extensionsShowInLauncher =
            defaults.object(forKey: Key.extensionsShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.extensionsShowInLauncher.rawValue)
        extensionPackageManager =
            defaults.string(forKey: Key.extensionPackageManager.rawValue)
            .flatMap(ExtensionPackageManager.init(rawValue:)) ?? .automatic
        extensionCustomSearchPaths =
            defaults.stringArray(forKey: Key.extensionCustomSearchPaths.rawValue) ?? []
        // Opt-in, like extensions: until it is asked for, EventKit is never loaded.
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled.rawValue)
        calendarShowInLauncher =
            defaults.object(forKey: Key.calendarShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.calendarShowInLauncher.rawValue)
        calendarLauncherLimit =
            defaults.object(forKey: Key.calendarLauncherLimit.rawValue)
            .flatMap { $0 as? Int }
            .flatMap(CalendarLauncherLimit.init(rawValue:)) ?? .five
        // No case is zero, so an unset key falls through to the default.
        calendarSpan =
            MeetingSpan(rawValue: defaults.integer(forKey: Key.calendarSpan.rawValue))
            ?? .todayAndTomorrow
        joinWindowMinutes =
            JoinWindow(rawValue: defaults.integer(forKey: Key.joinWindowMinutes.rawValue)) ?? .five
        autoJoinMeetings = defaults.bool(forKey: Key.autoJoinMeetings.rawValue)
        autoJoinConfirms =
            defaults.object(forKey: Key.autoJoinConfirms.rawValue) == nil
            || defaults.bool(forKey: Key.autoJoinConfirms.rawValue)
        autoJoinNamedProvidersOnly = defaults.bool(forKey: Key.autoJoinNamedProvidersOnly.rawValue)
        cameraPreview = defaults.bool(forKey: Key.cameraPreview.rawValue)
        meetingBrowserBundleID = defaults.string(forKey: Key.meetingBrowser.rawValue)
        // Both default to their zero case, so an unset key needs no presence check.
        menuBarEvents =
            MenuBarEvents(rawValue: defaults.integer(forKey: Key.menuBarEvents.rawValue)) ?? .today
        calendarMenuBarDisplay =
            CalendarMenuBarDisplay(
                rawValue: defaults.integer(forKey: Key.calendarMenuBarDisplay.rawValue))
            ?? .disabled
        menuBarLinkedEventsOnly =
            defaults.object(forKey: Key.menuBarLinkedEventsOnly.rawValue) == nil
            || defaults.bool(forKey: Key.menuBarLinkedEventsOnly.rawValue)
        calendarMenuBarHidesWhenEmpty =
            defaults.bool(forKey: Key.calendarMenuBarHidesWhenEmpty.rawValue)
        hideCurrentEvent =
            defaults.object(forKey: Key.hideCurrentEvent.rawValue)
            .flatMap { $0 as? Int }
            .flatMap(HideCurrentEvent.init(rawValue:)) ?? .dontHide
        navigationEnabled = defaults.bool(forKey: Key.navigationEnabled.rawValue)
        menuSearchDisabledApps =
            defaults.stringArray(forKey: Key.menuSearchDisabledApps.rawValue) ?? []
        menuSearchShowsAppleMenu = defaults.bool(forKey: Key.menuSearchShowsAppleMenu.rawValue)
        windowManagementEnabled = defaults.bool(forKey: Key.windowManagementEnabled.rawValue)
        windowManagementShowInLauncher =
            defaults.object(forKey: Key.windowManagementShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.windowManagementShowInLauncher.rawValue)
        // Unset reads as 0, which is the intended default anyway — no gap.
        windowGap = defaults.integer(forKey: Key.windowGap.rawValue)
        windowCycle =
            defaults.string(forKey: Key.windowCycle.rawValue).flatMap(WindowCycle.init) ?? .off
        windowLayoutsShowInLauncher =
            defaults.object(forKey: Key.windowLayoutsShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.windowLayoutsShowInLauncher.rawValue)
        windowRoomsShowInLauncher =
            defaults.object(forKey: Key.windowRoomsShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.windowRoomsShowInLauncher.rawValue)
        quicklinksEnabled = defaults.bool(forKey: Key.quicklinksEnabled.rawValue)
        quicklinksShowInLauncher =
            defaults.object(forKey: Key.quicklinksShowInLauncher.rawValue) == nil
            || defaults.bool(forKey: Key.quicklinksShowInLauncher.rawValue)
        appleShortcutsEnabled = defaults.bool(forKey: Key.appleShortcutsEnabled.rawValue)
        quicklinkOpensNewWindow = defaults.bool(forKey: Key.quicklinkOpensNewWindow.rawValue)
        quicklinkSelectionFallback =
            defaults.string(forKey: Key.quicklinkSelectionFallback.rawValue)
            .flatMap(QuicklinkSelectionFallback.init) ?? .ask
        quicklinkConfirmsBeforeDelete =
            defaults.object(forKey: Key.quicklinkConfirmsBeforeDelete.rawValue) == nil
            || defaults.bool(forKey: Key.quicklinkConfirmsBeforeDelete.rawValue)
        supportRemindersEnabled =
            defaults.object(forKey: Key.supportReminders.rawValue) == nil
            || defaults.bool(forKey: Key.supportReminders.rawValue)
        settingsFileEnabled = defaults.bool(forKey: Key.settingsFileEnabled.rawValue)
    }
}
