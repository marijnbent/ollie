import AppKit

@MainActor
final class AppSettings {
    var launcherEnabled = false
    var clipboardEnabled = false
    var snippetsEnabled = false
    var dictationEnabled = false
    var windowSwitcherEnabled = false
    var spacesEnabled = false
    var aiEnabled = false
    var screenNotesEnabled = false
    var typingSoundsEnabled = false
    var networkEnabled = false
    var notificationsEnabled = false
    var mediaImportEnabled = false
    var fileSearchEnabled = false
    var navigationEnabled = false
    var notesEnabled = false
    var calendarEnabled = false
    var extensionsEnabled = false
    var customCommandsEnabled = false
    var quicklinksEnabled = false
    var appleShortcutsEnabled = false
    var windowManagementEnabled = false
    var quickActionsEnabled = false
    var mcpEnabled = false
}

struct AppEntry: Sendable {
    enum Kind: Sendable { case command, quickAction }
    let id: String
    let name: String
    let url: URL
    let bundleID: String?
    let kind: Kind
    let settingsOwner: SettingsTab?
    let subtitle: String?
}

@main
@MainActor
struct FeatureAvailabilityTests {
    static func main() {
        let settings = AppSettings()
        settings.fileSearchEnabled = true
        settings.navigationEnabled = true
        settings.notesEnabled = true
        settings.calendarEnabled = true
        settings.extensionsEnabled = true
        settings.customCommandsEnabled = true
        settings.quicklinksEnabled = true
        settings.appleShortcutsEnabled = true
        settings.windowManagementEnabled = true
        settings.quickActionsEnabled = true
        settings.mcpEnabled = true

        let off = settings.featureAvailability
        for capability in FeatureCapability.allCases {
            precondition(!off.allows(capability), "All roots off blocks \(capability)")
        }
        for command in CommandID.allCases {
            if let capability = command.capability {
                precondition(!off.allows(capability), "Saved shortcut cannot invoke \(command)")
            }
        }
        for mode in PaletteMode.allCases {
            precondition(!off.allows(mode.capability), "No palette mode survives all-off")
        }
        precondition(SettingsTab.visible(for: off.enabledFeatures) ==
            [.features, .general, .shortcuts, .permissions, .backup, .about])

        for feature in OllieFeature.allCases {
            settings[keyPath: feature.enabledKeyPath] = true
            let availability = settings.featureAvailability
            for other in OllieFeature.allCases {
                precondition(availability.allows(.feature(other)) == (feature == other))
            }
            for capability in FeatureCapability.allCases where capability.owner != nil {
                let expected = capability == .screenExplanation ? false : capability.owner == feature
                precondition(availability.allows(capability) == expected)
            }
            settings[keyPath: feature.enabledKeyPath] = false
        }

        settings.screenNotesEnabled = true
        precondition(settings.allows(.feature(.screenNotes)))
        precondition(CommandID.explainScreen.owner == .screenNotes)
        precondition(!settings.allows(.feature(.launcher)))
        precondition(!settings.allows(.screenExplanation))
        settings.dictationEnabled = true
        precondition(settings.allows(.screenExplanation))
        precondition(HotKeyAction.command(.explainScreen).capability == .screenExplanation)
        settings.dictationEnabled = false
        precondition(!settings.allows(.screenExplanation))
        settings.screenNotesEnabled = false
        settings.snippetsEnabled = true
        precondition(settings.allows(.clipboardHistory))
        precondition(!settings.allows(.feature(.clipboard)))
        precondition(!settings.allows(.feature(.launcher)))
        settings.snippetsEnabled = false
        settings.clipboardEnabled = true
        precondition(settings.allows(.clipboardHistory))
        settings.spacesEnabled = true
        precondition(settings.allows(.spaceNavigation))
        precondition(!settings.allows(.windowManagement))
        settings.aiEnabled = true
        precondition(settings.allows(.quickActions))
        precondition(settings.allows(.mcp))
        precondition(!settings.allows(.extensions))
        precondition(HotKeyAction.command(.quickAI).capability == .feature(.ai))
        precondition(HotKeyAction.command(.searchEmoji).capability == .feature(.launcher))
        precondition(HotKeyAction.windowCommand(id: .nextSpace).capability == .spaceNavigation)
        precondition(HotKeyAction.command(.settings).capability == nil)
        settings.aiEnabled = false
        precondition(!settings.allows(.quickActions) && !settings.allows(.mcp))
        precondition(settings.quickActionsEnabled && settings.mcpEnabled)
        settings.launcherEnabled = true
        precondition(settings.allows(.extensions) && settings.allows(.notes))
        settings.extensionsEnabled = false
        precondition(!settings.allows(.extensions) && settings.allows(.notes))
        print("Feature ownership, all-off, independent roots and saved child settings passed")
    }
}
