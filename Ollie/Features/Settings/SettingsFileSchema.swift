import Foundation

/// Where each settings.json key lives; exhaustive, so a new key fails to build until it is bound.
@MainActor
enum SettingsFileSchema {
    static func bindings(
        settings: AppSettings, ai: AISettingsStore, dictation: DictationSettingsStore, mediaImport: MediaImportSettingsStore, quickActions: QuickActionSettingsStore,
        shortcuts: HotKeySettingsFile, launcher: LauncherSettingsFile,
        windowManagement: WindowManagementSettingsFile
    ) -> [SettingsFileBinding] {
        SettingsFileKey.available.map { key in
            binding(
                for: key, settings: settings, ai: ai, dictation: dictation, mediaImport: mediaImport, quickActions: quickActions,
                shortcuts: shortcuts, launcher: launcher, windowManagement: windowManagement)
        }
    }

    private static func binding(
        for key: SettingsFileKey, settings: AppSettings, ai: AISettingsStore,
        dictation: DictationSettingsStore, mediaImport: MediaImportSettingsStore,
        quickActions: QuickActionSettingsStore, shortcuts: HotKeySettingsFile,
        launcher: LauncherSettingsFile, windowManagement: WindowManagementSettingsFile
    ) -> SettingsFileBinding {
        func bind<Root: AnyObject, Value: SettingsFileValue>(
            _ root: Root, _ path: ReferenceWritableKeyPath<Root, Value>,
            accept: @escaping (Value) -> Value? = { $0 }
        ) -> SettingsFileBinding {
            SettingsFileBinding(key, root, path, accept: accept)
        }

        switch key {
        case .dictationTranscriptionProvider: return .codable(key, dictation, \.transcriptionProvider)
        case .dictationShortcuts: return .codable(key, dictation, \.shortcuts) {
            Set($0.map(\.id)).count == $0.count && Set($0.map(\.key)).count == $0.count
        }
        case .dictationPrompts: return .codable(key, dictation, \.prompts) { Set($0.map(\.id)).count == $0.count }
        case .dictationEscToCancelRecording: return .codable(key, dictation, \.escToCancelRecording)
        case .dictationPlaySoundEffects: return .codable(key, dictation, \.playSoundEffects)
        case .dictationMuteMediaDuringRecording: return .codable(key, dictation, \.muteMediaDuringRecording)
        case .dictationRestoreClipboardAfterPaste: return .codable(key, dictation, \.restoreClipboardAfterPaste)
        case .dictationShowLanguageInRecorderWidget: return .codable(key, dictation, \.showLanguageInRecorderWidget)
        case .dictationShowLiveTranscriptInRecorderWidget: return .codable(key, dictation, \.showLiveTranscriptInRecorderWidget)
        case .dictationOverlayPosition: return .codable(key, dictation, \.overlayPosition)
        case .dictationDeepgramLanguage: return .codable(key, dictation, \.deepgramLanguage)
        case .dictationAutomaticLanguageCandidates: return .codable(key, dictation, \.automaticLanguageCandidates)
        case .dictationStarredDeepgramLanguages: return .codable(key, dictation, \.starredDeepgramLanguages)
        case .dictationHistoryLimit: return .codable(key, dictation, \.historyLimit)
        case .dictationAppTranscriptionLanguageOverrides: return .codable(key, dictation, \.appTranscriptionLanguageOverrides)
        case .dictationAudioInput: return bind(dictation, \.audioInputStoredValue)
        case .mediaImportOpenOnDetection: return bind(mediaImport, \.openOnDetection)

        case .spacesTransitionSpeed:
            return bind(settings, \.spacesTransitionSpeed) { SpaceTransitionSpeed(rawValue: $0) == nil ? nil : $0 }
        case .spacesPreviousShortcut:
            return shortcuts.binding(for: key, action: .windowCommand(id: .previousSpace), name: "Previous Space")
        case .spacesNextShortcut:
            return shortcuts.binding(for: key, action: .windowCommand(id: .nextSpace), name: "Next Space")
        case .switcherCommandTab: return bind(settings, \.switcherCommandTab)
        case .switcherCommandBacktick: return bind(settings, \.switcherCommandBacktick)
        case .switcherWindowSource: return bind(settings, \.switcherWindowSource) { ["allSpaces", "visibleAndFullScreenSpaces", "visibleSpaces"].contains($0) ? $0 : nil }
        case .switcherMinimizedMode: return bind(settings, \.switcherMinimizedMode) { ["show", "showAtBottom", "doNotShow"].contains($0) ? $0 : nil }
        case .switcherHiddenMode: return bind(settings, \.switcherHiddenMode) { ["show", "showAtBottom", "doNotShow"].contains($0) ? $0 : nil }
        case .switcherAppsWithoutWindowsMode: return bind(settings, \.switcherAppsWithoutWindowsMode) { ["show", "showAtBottom", "doNotShow"].contains($0) ? $0 : nil }
        case .switcherImmediatePreview: return bind(settings, \.switcherImmediatePreview)
        case .diagnosticsEnabled: return bind(settings, \.diagnosticsEnabled)
        case .clipboardHistoryDays: return bind(settings, \.clipboardHistoryDays) { [1, 7, 30, 180].contains($0) ? $0 : nil }
        case .launcherEnabled: return bind(settings, \.launcherEnabled)
        case .screenNotesShortcut:
            return shortcuts.binding(for: key, action: .command(.explainScreen), name: "Screen Note")
        case .typingSoundProfile: return bind(settings, \.typingSoundProfile) { SoundProfile(rawValue: $0) == nil ? nil : $0 }
        case .typingSoundVolume: return bind(settings, \.typingSoundVolume) { (0...100).contains($0) ? $0 : nil }
        case .typingSoundDownVolume: return bind(settings, \.typingSoundDownVolume) { (0...100).contains($0) ? $0 : nil }
        case .typingSoundUpVolume: return bind(settings, \.typingSoundUpVolume) { (0...100).contains($0) ? $0 : nil }
        case .typingMouseEnabled: return bind(settings, \.typingMouseEnabled)
        case .typingMouseVolume: return bind(settings, \.typingMouseVolume) { (0...100).contains($0) ? $0 : nil }

        case .launcherShortcut:
            return shortcuts.binding(for: key, action: .togglePalette, name: "App Launcher")
        case .showInMenuBar: return bind(settings, \.showInMenuBar)
        case .automaticallyCheckForUpdates: return bind(settings, \.automaticallyCheckForUpdates)
        case .popToRootTimeout: return bind(settings, \.popToRootTimeout)
        case .escapeKeyBehavior: return bind(settings, \.escapeKeyBehavior)
        case .autoSwitchInputSource: return bind(settings, \.autoSwitchInputSourceID)
        case .supportReminders: return bind(settings, \.supportRemindersEnabled)
        case .appearance: return bind(settings, \.appearance)
        case .paletteDensity: return bind(settings, \.paletteDensity)
        case .interfaceSize: return bind(settings, \.interfaceSize)
        case .compactMode: return bind(settings, \.compactMode)
        case .openOnCursorScreen: return bind(settings, \.openOnCursorScreen)
        case .paletteDraggable: return bind(settings, \.paletteDraggable)
        case .calcNumberStyle: return bind(settings, \.calcNumberStyle)
        case .rootSearchSensitivity: return bind(settings, \.rootSearchSensitivity)
        case .applicationsEnabled: return launcher.kindBinding(for: key, kind: .application)
        case .searchScopes: return bind(settings, \.searchScopes) { SearchScopes.normalize($0) }
        case .applications: return launcher.appsBinding(for: key)
        case .systemSettingsEnabled: return launcher.kindBinding(for: key, kind: .systemSettings)
        case .systemSettings: return launcher.panesBinding(for: key)
        case .systemActionsEnabled: return launcher.kindBinding(for: key, kind: .systemAction)
        case .systemActions: return launcher.systemActionsBinding(for: key)
        case .builtInCommandsEnabled: return launcher.kindBinding(for: key, kind: .command)
        case .builtInCommands: return launcher.commandsBinding(for: key, owner: nil)
        case .customCommandsEnabled: return bind(settings, \.customCommandsEnabled)
        case .customCommandsShowInLauncher: return bind(settings, \.customCommandsShowInLauncher)
        case .quicklinksEnabled: return bind(settings, \.quicklinksEnabled)
        case .quicklinksShowInLauncher: return bind(settings, \.quicklinksShowInLauncher)
        case .quicklinkOpensNewWindow: return bind(settings, \.quicklinkOpensNewWindow)
        case .quicklinkSelectionFallback: return bind(settings, \.quicklinkSelectionFallback)
        case .quicklinkConfirmsBeforeDelete: return bind(settings, \.quicklinkConfirmsBeforeDelete)
        case .quicklinkCommands: return launcher.commandsBinding(for: key, owner: .quicklinks)
        case .appleShortcutsEnabled: return bind(settings, \.appleShortcutsEnabled)
        case .aiEnabled: return bind(settings, \.aiEnabled)
        case .aiWebSearch: return bind(ai, \.webSearchEnabled)
        case .aiSystemPrompt: return bind(ai, \.systemPrompt)
        case .aiSystemPromptEnabled: return bind(ai, \.systemPromptEnabled)
        case .aiRetention: return bind(ai, \.retention)
        case .aiOpensTo: return bind(ai, \.opensTo)
        case .aiNewChatAfter: return bind(ai, \.newChatAfter)
        case .aiToolRounds: return bind(ai, \.toolRounds)
        case .aiCommands: return launcher.commandsBinding(for: key, owner: .ai)
        case .quickActionLanguage: return bind(quickActions, \.settings.targetLanguage)
        case .quickActionCommands: return launcher.commandsBinding(for: key, owner: .quickActions)
        case .fileSearchEnabled: return bind(settings, \.fileSearchEnabled)
        case .fileSearchScopes: return bind(settings, \.fileSearchScopes)
        case .fileSearchIgnorePatterns: return bind(settings, \.fileSearchIgnorePatterns)
        case .fileSearchCommands: return launcher.commandsBinding(for: key, owner: .fileSearch)
        case .notesEnabled: return bind(settings, \.notesEnabled)
        case .notesRendersMarkdown: return bind(settings, \.notesRendersMarkdown)
        case .notesShowsFormattingBar: return bind(settings, \.notesShowsFormattingBar)
        case .notesFolder: return bind(settings, \.notesFolder, accept: folder)
        case .notesCommands: return launcher.commandsBinding(for: key, owner: .notes)
        case .navigationEnabled: return bind(settings, \.navigationEnabled)
        case .menuSearchShowsAppleMenu: return bind(settings, \.menuSearchShowsAppleMenu)
        case .menuSearchDisabledApps: return bind(settings, \.menuSearchDisabledApps)
        case .navigationCommands: return launcher.commandsBinding(for: key, owner: .navigation)
        case .windowManagementEnabled: return bind(settings, \.windowManagementEnabled)
        case .windowManagementShowInLauncher:
            return bind(settings, \.windowManagementShowInLauncher)
        case .windowGap:
            return bind(settings, \.windowGap) {
                WindowPlacementEngine.gapRange.contains($0) ? $0 : nil
            }
        case .windowCycle: return bind(settings, \.windowCycle)
        case .windowLayoutsShowInLauncher: return bind(settings, \.windowLayoutsShowInLauncher)
        case .windowRoomsShowInLauncher: return bind(settings, \.windowRoomsShowInLauncher)
        case .windowShortcuts: return windowManagement.commandShortcutsBinding(for: key)
        case .windowAliases: return windowManagement.commandAliasesBinding(for: key)
        case .customWindowSizes: return windowManagement.customSizesBinding(for: key)
        case .windowLayouts: return windowManagement.layoutsBinding(for: key)
        case .windowRooms: return windowManagement.roomsBinding(for: key)
        case .windowManagementCommands:
            return launcher.commandsBinding(for: key, owner: .windowManagement)
        case .emojiSkinTone: return bind(settings, \.emojiSkinTone)
        case .emojiGridColumns: return bind(settings, \.emojiGridColumns)
        case .emojiCommands: return launcher.commandsBinding(for: key, owner: .emoji)
        case .calendarShowInLauncher: return bind(settings, \.calendarShowInLauncher)
        case .calendarLauncherLimit: return bind(settings, \.calendarLauncherLimit)
        case .calendarSpan: return bind(settings, \.calendarSpan)
        case .joinWindowMinutes: return bind(settings, \.joinWindowMinutes)
        case .autoJoinConfirms: return bind(settings, \.autoJoinConfirms)
        case .autoJoinNamedProvidersOnly: return bind(settings, \.autoJoinNamedProvidersOnly)
        case .meetingBrowser: return bind(settings, \.meetingBrowserBundleID)
        case .calendarMenuBarDisplay: return bind(settings, \.calendarMenuBarDisplay)
        case .menuBarEvents: return bind(settings, \.menuBarEvents)
        case .menuBarLinkedEventsOnly: return bind(settings, \.menuBarLinkedEventsOnly)
        case .calendarMenuBarHidesWhenEmpty: return bind(settings, \.calendarMenuBarHidesWhenEmpty)
        case .hideCurrentEvent: return bind(settings, \.hideCurrentEvent)
        case .calendarCommands: return launcher.commandsBinding(for: key, owner: .calendar)
        case .extensionsShowInLauncher: return bind(settings, \.extensionsShowInLauncher)
        }
    }

    /// A folder is absolute or under `~/`; null puts it back in Application Support.
    private static func folder(_ path: String?) -> String?? {
        guard let path else { return .some(nil) }
        return AppPaths.isFolderPath(path) ? path : nil
    }
}


extension PopToRootTimeout: SettingsFileRawValue {}
extension EscapeKeyBehavior: SettingsFileRawValue {}
extension AppAppearance: SettingsFileRawValue {}
extension InterfaceSize: SettingsFileRawValue {}
extension PaletteDensity: SettingsFileRawValue {}
extension CalcNumberStyle: SettingsFileRawValue {}
extension SearchSensitivity: SettingsFileRawValue {}
extension QuicklinkSelectionFallback: SettingsFileRawValue {}
extension WindowCycle: SettingsFileRawValue {}
extension EmojiSkinTone: SettingsFileRawValue {}
extension EmojiGridColumns: SettingsFileRawValue {}
extension JoinWindow: SettingsFileRawValue {}

extension AIRetention: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .forever: "forever"
        }
    }
}

extension AIOpensTo: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .recent: "recent"
        case .newConversation: "newConversation"
        }
    }
}

extension AINewChatAfter: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .twoMinutes: 2
        case .fiveMinutes: 5
        case .tenMinutes: 10
        case .thirtyMinutes: 30
        case .never: "never"
        }
    }
}

extension AIToolRounds: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .ten: 10
        case .twentyFive: 25
        case .fifty: 50
        case .hundred: 100
        case .unlimited: "unlimited"
        }
    }
}

extension CalendarLauncherLimit: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .one: 1
        case .three: 3
        case .five: 5
        case .all: "all"
        }
    }
}

extension MeetingSpan: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .today: "today"
        case .todayAndTomorrow: "todayAndTomorrow"
        case .nextSevenDays: "nextSevenDays"
        }
    }
}

extension CalendarMenuBarDisplay: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .disabled: "disabled"
        case .meetingIcon: "meetingIcon"
        case .meetingTitle: "meetingTitle"
        }
    }
}

extension MenuBarEvents: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .today: "today"
        case .two: 2
        case .five: 5
        case .ten: 10
        case .thirty: 30
        }
    }
}

extension HideCurrentEvent: SettingsFileToken {
    var settingsToken: SettingsFileJSON {
        switch self {
        case .dontHide: "never"
        case .automatically: 0
        case .afterFive: 5
        case .afterTen: 10
        case .afterThirty: 30
        }
    }
}
