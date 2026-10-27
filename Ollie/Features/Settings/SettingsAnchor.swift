/// One `Section` inside a pane, named once so the catalog and the pane cannot disagree: the search
/// result carries the anchor, the pane's `.settingsAnchor(_:)` marks the section it scrolls to.
struct SettingsAnchor: Hashable, Sendable {
    let tab: SettingsTab
    /// The `Section`'s own header text, which is also what a result's breadcrumb reads.
    let title: String
}

// Named `<pane><Section>` throughout, so the constant for a section is always guessable from it.
extension SettingsAnchor {
    static let generalGlobalShortcuts = Self(tab: .general, title: "Global Shortcuts")
    static let generalSearch = Self(tab: .general, title: "Search")
    static let generalAppearance = Self(tab: .general, title: "Appearance")
    static let generalGeneral = Self(tab: .general, title: "General")

    static let applicationsSearchScopes = Self(tab: .applications, title: "Search Scopes")
    static let applicationsApplications = Self(tab: .applications, title: "Applications")


    static let emojiCommands = Self(tab: .emoji, title: "Commands")
    static let emojiAppearance = Self(tab: .emoji, title: "Appearance")

    static let aiAI = Self(tab: .ai, title: "AI")
    static let aiProviders = Self(tab: .ai, title: "Providers")
    static let aiDefault = Self(tab: .ai, title: "Default")
    static let aiChat = Self(tab: .ai, title: "Chat")
    static let aiConversations = Self(tab: .ai, title: "Conversations")
    static let aiSystemPrompt = Self(tab: .ai, title: "System prompt")
    static let aiMCPServers = Self(tab: .ai, title: "MCP Servers")
    static let aiCommands = Self(tab: .ai, title: "Commands")

    static let windowManagementLayouts = Self(tab: .windowManagement, title: "Window Layouts")
    static let windowManagementRooms = Self(tab: .windowManagement, title: "Rooms")
    static let windowManagementCustomSizes = Self(tab: .windowManagement, title: "Custom Sizes")

    static let permissionsAccessibility = Self(tab: .permissions, title: "Accessibility")

    static let backupExport = Self(tab: .backup, title: "Export")
    static let backupImport = Self(tab: .backup, title: "Import")
    static let backupImportFromRaycast = Self(tab: .backup, title: "Import from Raycast")
    static let backupSettingsFile = Self(tab: .backup, title: "Settings File")

    static let aboutAbout = Self(tab: .about, title: "About")
    static let aboutLinks = Self(tab: .about, title: "Links")
}

/// Where a search result lands: a whole section, or one row inside it.
enum SettingsTarget: Hashable, Sendable {
    case section(SettingsAnchor)
    /// The row's visible title, which is also the catalog entry's — they are the same string.
    case row(SettingsAnchor, String)

    var anchor: SettingsAnchor {
        switch self {
        case .section(let anchor), .row(let anchor, _): return anchor
        }
    }

    var tab: SettingsTab { anchor.tab }
}

/// One jump asked for by a search result. The token is what makes picking the same result twice
/// scroll and pulse again, rather than comparing equal and doing nothing.
struct SettingsScrollRequest: Equatable, Sendable {
    let target: SettingsTarget
    let token: Int
}
