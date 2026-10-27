extension OllieFeature {
    @MainActor var enabledKeyPath: ReferenceWritableKeyPath<AppSettings, Bool> {
        switch self {
        case .launcher: \.launcherEnabled
        case .clipboard: \.clipboardEnabled
        case .snippets: \.snippetsEnabled
        case .dictation: \.dictationEnabled
        case .windowSwitcher: \.windowSwitcherEnabled
        case .spaces: \.spacesEnabled
        case .ai: \.aiEnabled
        case .screenNotes: \.screenNotesEnabled
        case .typingSounds: \.typingSoundsEnabled
        case .network: \.networkEnabled
        case .notifications: \.notificationsEnabled
        case .mediaImport: \.mediaImportEnabled
        }
    }
}

extension AppSettings {
    var featureAvailability: FeatureAvailability {
        let features = Set(OllieFeature.allCases.filter { self[keyPath: $0.enabledKeyPath] })
        let capabilities: [(FeatureCapability, Bool)] = [
            (.fileSearch, fileSearchEnabled), (.navigation, navigationEnabled),
            (.notes, notesEnabled), (.calendar, calendarEnabled), (.extensions, extensionsEnabled),
            (.customCommands, customCommandsEnabled), (.quicklinks, quicklinksEnabled),
            (.appleShortcuts, appleShortcutsEnabled), (.windowManagement, windowManagementEnabled),
            (.quickActions, quickActionsEnabled), (.mcp, mcpEnabled),
        ]
        return FeatureAvailability(enabledFeatures: features,
            enabledCapabilities: Set(capabilities.filter(\.1).map(\.0)))
    }

    func allows(_ capability: FeatureCapability) -> Bool {
        featureAvailability.allows(capability)
    }
}

extension CommandID {
    var capability: FeatureCapability? {
        switch self {
        case .clipboardHistory: .clipboardHistory
        case .explainScreen: .screenExplanation
        case .exportSettings, .importSettings, .importFromRaycast, .checkForUpdates,
             .settings, .about, .support, .restart, .quit: nil
        default: owner?.capability ?? .feature(.launcher)
        }
    }
}

extension HotKeyAction {
    var capability: FeatureCapability? {
        switch self {
        case .command(let command): command.capability
        case .windowCommand(let command) where command == .previousSpace || command == .nextSpace:
            .spaceNavigation
        case .windowCommand, .windowLayout, .windowRoom, .customWindowSize: .windowManagement
        case .customCommand: .customCommands
        case .quicklink: .quicklinks
        case .quickAction: .quickActions
        case .appleShortcut: .appleShortcuts
        case .extensionCommand: .extensions
        case .togglePalette, .app, .settingsPane, .systemAction: .feature(.launcher)
        }
    }
}
