enum SettingsTab: CaseIterable, Identifiable {
    case features, shortcuts, dictation, windowSwitcher, spaces, clipboard, snippets, mediaImport, notifications, network, typingSounds, screenNotes, general, applications, systemSettings, systemActions, commands, quicklinks, appleShortcuts,
        fallbacks, fileSearch, windowManagement, navigation, notes, calendar, emoji,
        ai, quickActions, extensions, permissions, backup, about
    static let available: [Self] = [.features, .general, .shortcuts, .applications, .clipboard, .snippets, .dictation, .windowSwitcher, .spaces, .emoji, .ai, .screenNotes, .typingSounds, .network, .notifications, .mediaImport, .permissions, .backup, .about]

    /// The case, never an index: a selectable `List` flattens section and row IDs together.
    var id: Self { self }

    var title: String {
        switch self {
        case .features: return "Features"
        case .shortcuts: return "Shortcuts"
        case .dictation: return "Dictation"
        case .windowSwitcher: return "Window Switcher"
        case .spaces: return "Spaces"
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        case .mediaImport: return "Media Import"
        case .notifications: return "Notifications"
        case .network: return "Network"
        case .screenNotes: return "Screen Notes"
        case .typingSounds: return "Typing Sounds"
        case .general: return "General"
        case .applications: return "Applications"
        case .systemSettings: return "System Settings"
        case .systemActions: return "System Actions"
        case .commands: return "Commands"
        case .quicklinks: return "Quicklinks"
        case .appleShortcuts: return "Apple Shortcuts"
        case .fallbacks: return "Fallbacks"
        case .ai: return "AI"
        case .quickActions: return "Quick Actions"
        case .fileSearch: return "File Search"
        case .notes: return "Notes"
        case .navigation: return "Navigation"
        case .windowManagement: return "Window Management"
        case .emoji: return "Emoji & Symbols"
        case .calendar: return "Calendar"
        case .extensions: return "Extensions"
        case .permissions: return "Permissions"
        case .backup: return "Backup"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .features: return "square.grid.2x2"
        case .shortcuts: return "keyboard"
        case .dictation: return "mic"
        case .windowSwitcher: return "rectangle.on.rectangle"
        case .spaces: return "rectangle.split.3x1"
        case .clipboard: return "clipboard"
        case .snippets: return "text.badge.plus"
        case .mediaImport: return "externaldrive.badge.plus"
        case .notifications: return "bell"
        case .network: return "network"
        case .screenNotes: return "scribble.variable"
        case .typingSounds: return "speaker.wave.2"
        case .general: return "switch.2"
        case .applications: return "square.grid.2x2"
        case .systemSettings: return "gearshape"
        case .systemActions: return "bolt"
        case .commands: return "terminal"
        case .quicklinks: return "link"
        case .appleShortcuts: return "square.2.layers.3d"
        case .fallbacks: return "arrow.turn.down.right"
        case .ai: return "sparkles"
        case .quickActions: return "wand.and.sparkles"
        case .fileSearch: return "doc.text.magnifyingglass"
        case .notes: return "text.page"
        case .navigation: return "arrow.left.arrow.right"
        case .windowManagement: return "macwindow"
        case .emoji: return "face.smiling"
        case .calendar: return "calendar"
        case .extensions: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .backup: return "arrow.up.arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

enum SettingsSection: CaseIterable, Identifiable {
    case app, advanced
    var id: Self { self }

    var title: String {
        switch self {
        case .app: "Ollie"
        case .advanced: "Advanced"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .app: [.features, .general, .shortcuts, .applications, .clipboard, .snippets, .dictation, .windowSwitcher, .spaces, .emoji, .ai, .screenNotes, .typingSounds, .network, .notifications, .mediaImport]
        case .advanced: [.permissions, .backup, .about]
        }
    }
}


extension OllieFeature {
    var settingsTab: SettingsTab {
        switch self {
        case .launcher: .applications
        case .clipboard: .clipboard
        case .snippets: .snippets
        case .dictation: .dictation
        case .windowSwitcher: .windowSwitcher
        case .spaces: .spaces
        case .ai: .ai
        case .screenNotes: .screenNotes
        case .typingSounds: .typingSounds
        case .network: .network
        case .notifications: .notifications
        case .mediaImport: .mediaImport
        }
    }

    var title: String { self == .launcher ? "Launcher" : settingsTab.title }
}

extension SettingsTab {
    var feature: OllieFeature? {
        capability?.owner
    }

    static func visible(for enabled: Set<OllieFeature>) -> [Self] {
        available.filter { tab in
            guard let feature = tab.feature else { return true }
            return enabled.contains(feature)
        }
    }
}

extension SettingsTab {
    var capability: FeatureCapability? {
        switch self {
        case .applications, .systemSettings, .systemActions, .commands, .fallbacks, .emoji:
            .feature(.launcher)
        case .clipboard: .feature(.clipboard)
        case .snippets: .feature(.snippets)
        case .dictation: .feature(.dictation)
        case .windowSwitcher: .feature(.windowSwitcher)
        case .spaces: .feature(.spaces)
        case .ai: .feature(.ai)
        case .screenNotes: .feature(.screenNotes)
        case .typingSounds: .feature(.typingSounds)
        case .network: .feature(.network)
        case .notifications: .feature(.notifications)
        case .mediaImport: .feature(.mediaImport)
        case .fileSearch: .fileSearch
        case .navigation: .navigation
        case .notes: .notes
        case .calendar: .calendar
        case .extensions: .extensions
        case .quicklinks: .quicklinks
        case .appleShortcuts: .appleShortcuts
        case .windowManagement: .windowManagement
        case .quickActions: .quickActions
        case .features, .general, .shortcuts, .permissions, .backup, .about: nil
        }
    }
}
