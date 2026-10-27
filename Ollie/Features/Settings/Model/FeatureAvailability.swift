enum OllieFeature: CaseIterable, Identifiable, Hashable, Sendable {
    case launcher, clipboard, snippets, dictation, windowSwitcher, spaces, ai
    case screenNotes, typingSounds, network, notifications, mediaImport

    var id: Self { self }
}

enum FeatureCapability: Hashable, Sendable, CaseIterable {
    case feature(OllieFeature)
    case clipboardHistory, spaceNavigation, screenExplanation
    case fileSearch, navigation, notes, calendar, extensions
    case customCommands, quicklinks, appleShortcuts, windowManagement
    case quickActions, mcp

    static var allCases: [Self] {
        OllieFeature.allCases.map(Self.feature) + [
            .clipboardHistory, .spaceNavigation, .screenExplanation, .fileSearch, .navigation, .notes,
            .calendar, .extensions, .customCommands, .quicklinks, .appleShortcuts,
            .windowManagement, .quickActions, .mcp,
        ]
    }

    var owner: OllieFeature? {
        switch self {
        case .feature(let feature): feature
        case .clipboardHistory, .spaceNavigation: nil
        case .quickActions, .mcp: .ai
        case .screenExplanation: .screenNotes
        default: .launcher
        }
    }
}

struct FeatureAvailability: Equatable, Sendable {
    var enabledFeatures: Set<OllieFeature>
    var enabledCapabilities: Set<FeatureCapability> = []

    func allows(_ capability: FeatureCapability) -> Bool {
        switch capability {
        case .feature(let feature): return enabledFeatures.contains(feature)
        case .clipboardHistory:
            return enabledFeatures.contains(.clipboard) || enabledFeatures.contains(.snippets)
        case .screenExplanation:
            return enabledFeatures.contains(.screenNotes) && enabledFeatures.contains(.dictation)
        case .spaceNavigation:
            return enabledFeatures.contains(.spaces) || allows(.windowManagement)
        default:
            guard let owner = capability.owner else { return false }
            return enabledFeatures.contains(owner) && enabledCapabilities.contains(capability)
        }
    }
}

