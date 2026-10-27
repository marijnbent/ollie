import Foundation

/// One searchable place in Settings: a pane, or a row inside one of its `Form` sections.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    let tab: SettingsTab
    /// Where picking this result lands; nil for the pane itself, which is its own result.
    let target: SettingsTarget?
    let title: String
    /// Words a user might type that the visible title doesn't contain.
    let keywords: [String]

    /// Taking the pane from the target is what makes a row filed under the wrong pane unwritable.
    private init(_ target: SettingsTarget, _ title: String, _ keywords: [String]) {
        self.tab = target.tab
        self.target = target
        self.title = title
        self.keywords = keywords
    }

    /// One setting, which its pane marks with a matching `SettingsRowTitle`.
    init(_ anchor: SettingsAnchor, _ title: String, keywords: [String] = []) {
        self.init(.row(anchor, title), title, keywords)
    }

    /// A whole group, for a result no single row answers — a list, or a section's master switch.
    init(group anchor: SettingsAnchor, _ title: String, keywords: [String] = []) {
        self.init(.section(anchor), title, keywords)
    }

    init(pane: SettingsTab, keywords: [String] = []) {
        self.tab = pane
        self.target = nil
        self.title = pane.title
        self.keywords = keywords
    }

    var feature: OllieFeature? {
        if tab == .general {
            if anchor == .generalGlobalShortcuts || anchor == .generalSearch { return .launcher }
            let launcherRows: Set<String> = ["Pop to Root Search", "Escape Key Behavior", "Auto-switch input source", "Layout", "Follow the cursor across displays", "Drag to reposition"]
            if launcherRows.contains(title) { return .launcher }
        }
        return tab.feature
    }

    var anchor: SettingsAnchor? { target?.anchor }

    var id: String { "\(tab.title)/\(anchor?.title ?? "")/\(title)" }

    /// The result row's second line — "General", or "General › Appearance".
    var breadcrumb: String {
        guard let anchor, anchor.title != tab.title else { return tab.title }
        return "\(tab.title) › \(anchor.title)"
    }
}

/// What Settings offers to search. Hand-written: a `Form` can't be asked what rows it holds, so a
/// new row is searchable only once it is listed here.
enum SettingsSearchCatalog {
    struct Query: Sendable {
        let terms: [FuzzyMatch.Query]

        init(_ raw: String) {
            terms = raw.split(whereSeparator: \Character.isWhitespace).map {
                FuzzyMatch.Query(String($0))
            }
        }

        var isEmpty: Bool { terms.isEmpty }
    }

    static func results(for raw: String, limit: Int = 50, available: Set<SettingsTab> = Set(SettingsTab.available)) -> [SettingsSearchEntry] {
        let query = Query(raw)
        guard !query.isEmpty else { return [] }
        // Catalog order is the tie-break, so results don't reshuffle between equal-scoring rows.
        return
            entries
            .enumerated()
            .compactMap { item -> (entry: SettingsSearchEntry, score: Int, rank: Int)? in
                guard available.contains(item.element.tab),
                      item.element.feature.map({ available.contains($0.settingsTab) }) ?? true,
                      let score = score(query, item.element) else { return nil }
                return (item.element, score, item.offset)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.rank < $1.rank }
            .prefix(limit)
            .map(\.entry)
    }

    /// Every term must land somewhere; a term matched in the title outranks one found off it.
    private static func score(_ query: Query, _ entry: SettingsSearchEntry) -> Int? {
        var titleScore = 0
        var titleMatches = 0
        for term in query.terms {
            if let match = FuzzyMatch.match(term, candidate: entry.title) {
                titleMatches += 1
                titleScore += match.score
                continue
            }
            guard
                entry.keywords.contains(where: { FuzzyMatch.match(term, candidate: $0) != nil })
                    || FuzzyMatch.match(term, candidate: entry.breadcrumb) != nil
            else { return nil }
        }

        let band: Int
        if titleMatches == query.terms.count {
            band = 2_000_000
        } else if titleMatches > 0 {
            band = 1_000_000
        } else {
            band = 0
        }
        return band + titleScore + (entry.anchor == nil ? 500_000 : 0)
    }

    // MARK: - The index
    // Pane order, then section order within a pane, so this reads as a table of contents.

    static let entries: [SettingsSearchEntry] =
        general + applications + screenNotes + emoji + ai + permissions + backup + about
        + [.init(pane: .features, keywords: ["enable", "disable", "launcher", "clipboard", "snippets", "dictation", "window switcher", "spaces", "strafe", "screen drawing", "annotation", "AI", "typing sounds", "network", "notifications", "media import"]),
           .init(pane: .shortcuts, keywords: ["keyboard", "hotkeys", "bindings"]),
           .init(pane: .dictation, keywords: ["talkie", "speech", "microphone", "transcription", "mercury", "inception"]),
           .init(pane: .windowSwitcher, keywords: ["tabbie", "command tab", "windows"])]
        + [.init(pane: .clipboard, keywords: ["clippie", "history", "paste", "copy"]), .init(pane: .snippets, keywords: ["expand", "trigger", "text"]) ]
        + [.init(pane: .mediaImport, keywords: ["camera", "card", "video", "importie", "ffmpeg"])]
        + [.init(pane: .notifications, keywords: ["ntfy", "topics", "notifications"])]
        + [.init(pane: .network, keywords: ["traffic", "usage", "nettie", "bandwidth"])]
        + [.init(pane: .spaces, keywords: ["strafe", "swipe", "desktop", "transition", "instant", "trackpad"])]
        + [.init(pane: .typingSounds, keywords: ["keyboard", "sound", "typie", "volume", "mouse"])]

    private static let general: [SettingsSearchEntry] = [
        .init(pane: .general, keywords: ["preferences", "settings"]),
        .init(
            .generalGlobalShortcuts, "App Launcher",
            keywords: ["hotkey", "shortcut", "summon", "palette"]),
        .init(
            .generalGeneral, "Launch at login",
            keywords: ["startup", "login item", "start", "boot"]),
        .init(
            .generalGeneral, "Show in menu bar",
            keywords: ["menubar", "status item", "icon", "hide"]),
        .init(
            .generalGeneral, "Automatically check for updates",
            keywords: ["software", "update", "automatic", "disable", "popup"]),
        .init(.generalGeneral, "Diagnostics", keywords: ["logging", "logs", "debug", "performance", "troubleshoot"]),
        .init(.generalGeneral, "Setup", keywords: ["onboarding", "welcome", "spotlight", "fn", "globe", "permissions"]),
        .init(
            .generalGeneral, "Pop to Root Search",
            keywords: ["reset", "timeout", "back"]),
        .init(
            .generalGeneral, "Escape Key Behavior",
            keywords: ["escape", "esc", "back", "close", "navigate"]),
        .init(
            .generalGeneral, "Auto-switch input source",
            keywords: ["keyboard", "layout", "language", "abc"]),
        .init(
            .generalAppearance, "Theme",
            keywords: ["dark", "light", "mode", "appearance"]),
        .init(
            .generalAppearance, "Interface size",
            keywords: ["text size", "font size", "scale", "zoom", "bigger", "larger", "legible"]),
        .init(
            .generalAppearance, "Layout",
            keywords: ["compact", "expanded", "window mode", "slim", "search bar", "small", "grid"]),
        .init(
            .generalAppearance, "Density",
            keywords: ["compact", "comfortable", "spacing", "clipboard", "launcher"]),
        .init(
            .generalAppearance, "Follow the cursor across displays",
            keywords: ["monitor", "screen", "pointer", "multi display"]),
        .init(
            .generalAppearance, "Drag to reposition",
            keywords: ["move", "position", "window"]),
        .init(
            .generalSearch, "Search sensitivity",
            keywords: ["fuzzy", "strict", "loose", "matching", "typo", "root search"]),
        .init(
            .generalSearch, "Learned ranking",
            keywords: ["reset", "history", "order", "privacy"])
    ]

    private static let applications: [SettingsSearchEntry] = [
        .init(pane: .applications, keywords: ["apps", "index", "launcher"]),
        .init(
            .applicationsApplications, "Enable Applications",
            keywords: ["hide apps", "visibility"]),
        .init(
            group: .applicationsSearchScopes, "Search Scopes",
            keywords: ["folders", "indexed", "locations", "add folder"]),
        .init(
            group: .applicationsApplications, "Aliases and shortcuts",
            keywords: ["alias", "hotkey", "per app", "hide"])
    ]

    private static let screenNotes: [SettingsSearchEntry] = [
        .init(pane: .screenNotes, keywords: ["scrawl", "annotate", "marker", "screen note", "option", "screenshot",
                                             "dictation", "narrate", "shortcut", "hotkey"]),
    ]

    private static let emoji: [SettingsSearchEntry] = [
        .init(
            pane: .emoji,
            keywords: ["picker", "character", "unicode", "smiley"]),
        .init(
            group: .emojiCommands, "Emoji commands",
            keywords: ["shortcut", "hotkey", "launcher", "picker"]),
        .init(
            .emojiAppearance, "Emoji Skin Tone",
            keywords: ["colour", "color", "fitzpatrick", "default"]),
        .init(
            .emojiAppearance, "Column Count",
            keywords: ["columns", "density", "zoom", "six", "eight", "ten"])
    ]

    private static let ai: [SettingsSearchEntry] = [
        .init(
            pane: .ai, keywords: ["chat", "quick ai", "llm", "model", "openai", "anthropic"]),
        .init(
            .aiProviders, "Providers",
            keywords: [
                "sign in", "connect", "codex", "claude", "grok", "xai", "opencode", "cursor", "agent",
                "api key", "connection", "base url", "openai", "anthropic", "ollama", "models",
                "hide models"
            ]),
        .init(.aiDefault, "Default model", keywords: ["llm", "gpt", "claude", "grok"]),
        .init(.aiDefault, "Reasoning effort", keywords: ["thinking", "effort", "deepseek"]),
        .init(.aiChat, "Web search", keywords: ["browse", "internet"]),
        .init(.aiChat, "Tool call rounds", keywords: ["mcp", "tools", "limit", "loop", "agent", "unlimited"]),
        .init(
            .aiConversations, "Quick AI opens to",
            keywords: ["new chat", "last", "summon", "resume"]),
        .init(
            .aiConversations, "Start a new conversation after",
            keywords: ["idle", "timeout", "fresh"]),
        .init(
            .aiConversations, "Keep conversations",
            keywords: ["retention", "delete", "history", "privacy"]),
        .init(
            .aiSystemPrompt, "Send a system prompt",
            keywords: ["instructions", "persona"]),
        .init(
            .aiMCPServers, "Enable MCP servers",
            keywords: ["tools", "model context protocol"]),
        .init(
            .aiMCPServers, "Add MCP Server",
            keywords: ["tools", "model context protocol", "stdio"]),
        .init(
            group: .aiCommands, "AI commands",
            keywords: ["shortcut", "chat"])
    ]

    private static let permissions: [SettingsSearchEntry] = [
        .init(
            pane: .permissions,
            keywords: ["privacy", "tcc", "access", "grant"]),
        .init(
            .permissionsAccessibility, "Accessibility",
            keywords: ["paste", "keystrokes", "privacy", "grant"]),

    ]

    private static let backup: [SettingsSearchEntry] = [
        .init(
            pane: .backup,
            keywords: ["export", "import", "restore", "migrate", "raycast"]),
        .init(
            .backupExport, "Export Backup",
            keywords: ["save", "ollie file", "archive"]),
        .init(
            .backupImport, "Backup File",
            keywords: ["restore", "choose", "ollie file"]),
        .init(
            .backupImportFromRaycast, "Raycast Export",
            keywords: ["migrate", "rayconfig", "passphrase"]),
        .init(
            .backupSettingsFile, "Sync settings file",
            keywords: ["settings.json", "config", "json", "dotfiles", ".config", "edit"])
    ]

    private static let about: [SettingsSearchEntry] = [
        .init(
            pane: .about,
            keywords: ["version", "licence", "license", "credits"]),
        .init(
            .aboutAbout, "Check for Updates",
            keywords: ["version", "upgrade", "release"]),
        .init(
            group: .aboutLinks, "Links",
            keywords: ["github", "source", "issues", "website"]),
        .init(
            .aboutLinks, "Support",
            keywords: ["donate", "sponsor", "funding"])
    ]
}
