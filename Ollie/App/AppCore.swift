import AppKit

/// Single owner of every long-lived manager. Wired up once from the app delegate.
@MainActor
@Observable
final class AppCore {
    static let shared = AppCore()

    @ObservationIgnored private var restartRequested = false

    let launcherRanking: LauncherRankingStore
    let appIndex: AppIndex
    let customCommands = CustomCommandStore()
    let quicklinks = QuicklinkStore()
    let windowLayouts = WindowLayoutStore()
    let customWindowSizes = CustomWindowSizeStore()
    let rooms = RoomStore()
    let roomMinimums = RoomMinimumSizeStore()
    let roomParking = RoomParkingLedger(
        fileURL: AppPaths.applicationSupport().appendingPathComponent("room-parking.json"))
    let roomSession = RoomSession()
    let textInjector: TextInjector
    let clipboardNavigationDiagnostics = ClipboardNavigationDiagnostics()
    @ObservationIgnored private(set) lazy var compactMenu = CompactMenuController(core: self)
    @ObservationIgnored private(set) lazy var typingSounds = TypingSoundsCoordinator(settings: settings, ticker: healthTicker)
    @ObservationIgnored private(set) lazy var notifications = NotificationsCoordinator(settings: settings)
    @ObservationIgnored private(set) lazy var mediaImport = MediaImportCoordinator(core: self)
    @ObservationIgnored private(set) lazy var clipboard = ClipboardCoordinator(core: self, ticker: healthTicker)
    @ObservationIgnored private(set) lazy var windowSwitcher = WindowSwitcherCoordinator(core: self, ticker: healthTicker)
    @ObservationIgnored private(set) lazy var dictation = DictationCoordinator(core: self, ticker: healthTicker)
    @ObservationIgnored private(set) lazy var screenNotes = ScreenNoteCoordinator(core: self)
    let network = NetworkCoordinator()
    let hotKeys = HotKeyManager()
    let windowMover = WindowMover()
    let spaceSwitcher = SpaceSwitcher()
    @ObservationIgnored private(set) lazy var spaces = SpacesCoordinator(
        settings: settings, switcher: spaceSwitcher, ticker: healthTicker)
    let inputSourceSwitcher = InputSourceSwitcher()
    let settings: AppSettings
    /// Mirrors settings into settings.json; nil while the Backup pane's switch is off.
    @ObservationIgnored private var settingsFile: SettingsFileRepository?
    /// The file's launcher items, kept to apply a waiting record once its app is installed.
    @ObservationIgnored private var launcherSettingsFile: LauncherSettingsFile?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    /// The last verdict `trackChatRoute` acted on; nil until it has read one.
    @ObservationIgnored private var chatsRunTheirOwnTools: Bool?
    @ObservationIgnored private let iconStyle = IconStyleMonitor()
    let favorites = FavoritesStore()
    let visibility = VisibilityStore()
    let aliases = AliasStore()
    let fallbacks = FallbackStore()
    let calcHistory = CalculatorHistoryStore()
    let currencyRates = CurrencyRateStore()
    let regionNumberFormat = RegionNumberFormatMonitor()
    let calendarStore = CalendarStore()
    let meetingClock = MeetingClock()
    let updateChecker = UpdateCheckStore()
    let supportReminders: SupportReminderStore
    let emojiIndex = EmojiIndex()
    let frequentEmoji = FrequentEmojiStore()
    let pinnedEmoji = PinnedEmojiStore()
    let runningApps = RunningAppsMonitor()
    let palette = PaletteState()
    let fileSearch = FileSearchSession()
    let dictionary = DictionarySession()
    let menuSearch = MenuSearchSession()
    let activationPolicy = ActivationPolicy()
    let uninstall = UninstallSession()
    let notesStore: NotesStore
    let extensions: ExtensionManager
    let chatHistory: ChatHistoryStore
    let aiChats: AIChatSurfacesState
    let aiSettings = AISettingsStore(
        environmentStore: .keychain,
        isAppleIntelligenceAvailable: { AppleIntelligenceProvider.status().isAvailable })
    let mcpSettings = MCPSettingsStore()
    let mcpOAuth = MCPOAuthManager()
    @ObservationIgnored private(set) lazy var mcp = MCPServerManager(oauth: mcpOAuth)
    let quickActionSettings = QuickActionSettingsStore()
    let customQuickActions = CustomQuickActionStore()
    let chatGPTSubscription = ChatGPTSubscriptionManager()
    let installedAI = InstalledAIManager()
    @ObservationIgnored private var appliedLaunchRevisions: [InstalledAIKind: Int] = [:]

    /// Set when a quicklink editor should open with Settings; the pane consumes it.
    var pendingQuicklinkEdit: QuicklinkEditRequest?
    /// Set when a layout editor should open with Settings; the pane consumes it.
    var pendingWindowLayoutEdit: WindowLayoutEditRequest?

    @ObservationIgnored private(set) lazy var quicklinkCoordinator = QuicklinkCoordinator(
        store: quicklinks, settings: settings,
        appIndex: appIndex, injector: textInjector, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases,
        windowController: windowController,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        core: self)

    @ObservationIgnored private(set) lazy var paletteCoordinator = PaletteCoordinator(
        palette: palette, settings: settings, appIndex: appIndex,
        fileSearch: fileSearch, menuSearch: menuSearch,
        windowController: windowController)
    /// Its own window and lifecycle: neither coordinator shows or closes the other's surface.
    @ObservationIgnored private(set) lazy var settingsCoordinator = SettingsCoordinator(core: self)
    @ObservationIgnored private(set) lazy var onboardingCoordinator = OnboardingCoordinator(
        core: self)
    @ObservationIgnored private(set) lazy var systemActionCoordinator = SystemActionCoordinator(
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var uninstallCoordinator = UninstallCoordinator(
        session: uninstall, palette: palette, paletteCoordinator: paletteCoordinator,
        appIndex: appIndex, runningApps: runningApps, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases, core: self)
    @ObservationIgnored private(set) lazy var extensionCoordinator = ExtensionCoordinator(
        extensions: extensions, palette: palette, paletteCoordinator: paletteCoordinator,
        settingsCoordinator: settingsCoordinator, settings: settings, core: self)
    @ObservationIgnored private(set) lazy var windowCommandCoordinator = WindowCommandCoordinator(
        settings: settings, paletteCoordinator: paletteCoordinator, windowMover: windowMover,
        spaceSwitcher: spaceSwitcher, customSizes: customWindowSizes)
    @ObservationIgnored private(set) lazy var customWindowSizeCoordinator =
        CustomWindowSizeCoordinator(
            store: customWindowSizes, settings: settings, appIndex: appIndex, hotKeys: hotKeys,
            favorites: favorites, visibility: visibility, ranking: launcherRanking,
            aliases: aliases, core: self)
    @ObservationIgnored private(set) lazy var windowShortcutPresetCoordinator =
        WindowShortcutPresetCoordinator(hotKeys: hotKeys, core: self)
    @ObservationIgnored private(set) lazy var windowLayoutCoordinator = WindowLayoutCoordinator(
        store: windowLayouts, settings: settings, appIndex: appIndex, hotKeys: hotKeys,
        favorites: favorites, visibility: visibility, ranking: launcherRanking, aliases: aliases,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        core: self)
    @ObservationIgnored private(set) lazy var roomCoordinator = RoomCoordinator(
        store: rooms, minimums: roomMinimums, ledger: roomParking, session: roomSession,
        settings: settings, appIndex: appIndex, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases, palette: palette,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var customCommandCoordinator = CustomCommandCoordinator(
        store: customCommands, settings: settings, appIndex: appIndex,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        hotKeys: hotKeys, favorites: favorites, visibility: visibility,
        ranking: launcherRanking, aliases: aliases, activationPolicy: activationPolicy, core: self)
    @ObservationIgnored private(set) lazy var appleShortcutCoordinator = AppleShortcutCoordinator(
        settings: settings, appIndex: appIndex, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases,
        paletteCoordinator: paletteCoordinator, core: self)
    /// Window state, not a preference: it rides `UserDefaults` like the active note's filename.
    private nonisolated static let noteFormattingBarKey = "notesFormattingBarExpanded"
    @ObservationIgnored private(set) lazy var notesCoordinator = NotesCoordinator(
        store: notesStore,
        settings: settings,
        appIndex: appIndex,
        core: self,
        isFormattingBarExpanded: UserDefaults.standard.bool(forKey: Self.noteFormattingBarKey),
        saveFormattingBarExpanded: {
            UserDefaults.standard.set($0, forKey: Self.noteFormattingBarKey)
        })

    @ObservationIgnored private(set) lazy var launcherCoordinator = LauncherCoordinator(
        ranking: launcherRanking, windowController: windowController,
        paletteCoordinator: paletteCoordinator,
        settingsCoordinator: settingsCoordinator,
        customCommandCoordinator: customCommandCoordinator,
        systemActionCoordinator: systemActionCoordinator,
        quicklinkCoordinator: quicklinkCoordinator,
        windowCommandCoordinator: windowCommandCoordinator,
        windowLayoutCoordinator: windowLayoutCoordinator,
        fileSearchCoordinator: fileSearchCoordinator,
        menuSearchCoordinator: menuSearchCoordinator,
        notesCoordinator: notesCoordinator, extensionCoordinator: extensionCoordinator,
        calendarCoordinator: calendarCoordinator,
        core: self)
    @ObservationIgnored private(set) lazy var fallbackCoordinator = FallbackCoordinator(
        store: fallbacks, quicklinks: quicklinks, settings: settings, visibility: visibility,
        core: self)
    @ObservationIgnored private(set) lazy var emojiCoordinator = EmojiCoordinator(
        frequentEmoji: frequentEmoji, settings: settings, windowController: windowController,
        paletteCoordinator: paletteCoordinator)
    @ObservationIgnored private(set) lazy var calculatorCoordinator = CalculatorCoordinator(
        calcHistory: calcHistory, paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var calendarCoordinator = CalendarCoordinator(
        store: calendarStore, clock: meetingClock, appIndex: appIndex, settings: settings,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var fileSearchCoordinator = FileSearchCoordinator(
        settings: settings, appIndex: appIndex, session: fileSearch, palette: palette,
        paletteCoordinator: paletteCoordinator, windowController: windowController, core: self)
    @ObservationIgnored private(set) lazy var menuSearchCoordinator = MenuSearchCoordinator(
        settings: settings, appIndex: appIndex, session: menuSearch, palette: palette,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var cameraCoordinator = CameraCoordinator(core: self)
    @ObservationIgnored private(set) lazy var dictionaryCoordinator = DictionaryCoordinator(
        paletteCoordinator: paletteCoordinator)
    @ObservationIgnored private(set) lazy var updateCoordinator = UpdateCoordinator(
        store: updateChecker, core: self)
    @ObservationIgnored private(set) lazy var supportCoordinator = SupportCoordinator(
        store: supportReminders, core: self)
    @ObservationIgnored private(set) lazy var quickActionCoordinator = QuickActionCoordinator(
        settings: settings, store: quickActionSettings, customActions: customQuickActions,
        injector: textInjector, appIndex: appIndex, hotKeys: hotKeys, favorites: favorites,
        visibility: visibility, ranking: launcherRanking, aliases: aliases,
        paletteCoordinator: paletteCoordinator, core: self)
    @ObservationIgnored private(set) lazy var mcpCoordinator = MCPCoordinator(
        settings: settings, store: mcpSettings, manager: mcp, core: self)
    /// Its own window and lifecycle, like Settings; Quick AI is the palette's half of the feature.
    @ObservationIgnored private(set) lazy var aiChatCoordinator = AIChatCoordinator(
        chats: aiChats, settings: settings, appIndex: appIndex,
        paletteCoordinator: paletteCoordinator, settingsCoordinator: settingsCoordinator,
        core: self)
    @ObservationIgnored private(set) lazy var quickAICoordinator = QuickAICoordinator(
        chats: aiChats, settings: settings, palette: palette,
        paletteCoordinator: paletteCoordinator, core: self)

    @ObservationIgnored private lazy var windowController = PaletteWindowController(core: self)
    @ObservationIgnored private lazy var messageHUD = MessageHUDController(settings: settings)
    private(set) var isShowingDialog = false
    var isDimmingPaletteForDialog: Bool { isShowingDialog && windowController.isVisible }
    /// Every confirmation, report and prompt; it also stops a held hotkey stacking them.
    @ObservationIgnored private lazy var dialogs = DialogController(
        settings: settings,
        onPresentationChanged: { [weak self] isPresenting in
            guard let self else { return }
            isShowingDialog = isPresenting
        })
    private let healthTicker = HealthTicker()
    @ObservationIgnored private var launcherRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var appliedFeatures: FeatureAvailability?
    @ObservationIgnored private var notesFolderTask: Task<Void, Never>?

    private init() {
        let launcherRanking = LauncherRankingStore()
        let settings = AppSettings()
        let chatHistory = ChatHistoryStore(directory: AppPaths.applicationSupport())
        self.launcherRanking = launcherRanking
        self.settings = settings
        self.chatHistory = chatHistory
        supportReminders = SupportReminderStore(settings: settings)
        aiChats = AIChatSurfacesState(history: chatHistory)
        appIndex = AppIndex(ranking: launcherRanking, aliases: aliases)
        extensions = ExtensionManager()
        textInjector = TextInjector()
        let noteSelectionKey = "notesActiveFileName"
        notesStore = NotesStore(
            repository: Self.notesRepository(for: settings),
            loadSelection: {
                UserDefaults.standard.string(forKey: noteSelectionKey).map(NoteID.init(rawValue:))
            },
            saveSelection: { UserDefaults.standard.set($0?.rawValue, forKey: noteSelectionKey) })
    }

    func start() {
        Signposts.interval("AppCore.start") {
            // Shorten AppKit's ~2–3s tooltip delay; registration domain, so a user default wins.
            UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
            NSApp.setActivationPolicy(.accessory)
            if let error = LaunchAtLogin.refreshRegistrationAfterMove() { showMessage(error, tone: .danger) }
            settings.launchAtLogin = LaunchAtLogin.isEnabled
            applyAppearance()
            compactMenu.applyVisibility()
            observeEffectiveAppearance()
            pinnedEmoji.onPersistenceFailure = { [weak self] in
                self?.showMessage("Couldn't save Emoji & Symbols pins", tone: .danger)
            }

            appIndex.start(settings: settings)
            extensions.start(appIndex: appIndex, coordinator: extensionCoordinator)
            fileSearchCoordinator.applyPolicy()
            installedAI.launchSettings = { [aiSettings] in aiSettings.launch(for: $0) }
            chatGPTSubscription.launchSettings = { [aiSettings] in aiSettings.launch(for: .codex) }
            customQuickActions.onChange = { [weak self] _ in
                self?.quickActionCoordinator.applyCustomQuickActionsPresence()
            }
            // Before `hotKeys.start` even when off: the prune reads it.
            customQuickActions.load()
            customCommands.onChange = { [weak self] _ in
                self?.customCommandCoordinator.applyCustomCommandsPresence()
            }
            customWindowSizes.onChange = { [weak self] _ in
                self?.customWindowSizeCoordinator.applyCustomWindowSizesPresence()
            }
            windowLayouts.onChange = { [weak self] _ in
                self?.windowLayoutCoordinator.applyWindowLayoutsPresence()
            }
            rooms.onChange = { [weak self] _ in self?.roomCoordinator.applyRoomsPresence() }
            // A crash can leave windows parked off-screen; they come home before anything else.
            roomCoordinator.recoverParkedWindows()
            quicklinks.onChange = { [weak self] _ in
                self?.quicklinkCoordinator.applyQuicklinksPresence()
            }
            // Before `hotKeys.start` even when off: the prune reads it. docs/features/quicklinks.md
            quicklinks.load()
            paletteCoordinator.onLauncherShown = { [weak self] in
                self?.appleShortcutCoordinator.refresh()
            }
            paletteCoordinator.launcherBody = { [weak self] in
                guard let self else { return .list(count: 0) }
                return LauncherScreen.resolve(
                    appIndex: appIndex, favorites: favorites, visibility: visibility, core: self,
                    vm: palette
                ).body
            }
            paletteCoordinator.onScreenOpening = { [weak self] mode in
                switch mode {
                case .clipboard: self?.clipboard.refreshSearch()
                case .menuSearch: self?.menuSearchCoordinator.load()
                case .rooms, .roomWindows: self?.roomCoordinator.load()
                default: break
                }
            }
            updateCoordinator.applyEnabled()
            Task { await emojiIndex.load(languages: Locale.preferredLanguages) }
            updateChecker.onUpdateAvailable = { [weak self] release in
                self?.updateCoordinator.presentIfAvailable(release) ?? true
            }
            updateCoordinator.applyAutomaticChecking()
            supportReminders.onDue = { [weak self] in self?.supportCoordinator.presentIfDue() }
            supportReminders.start()

            hotKeys.modifierTapMonitor.healthTicker = healthTicker

            hotKeys.onTogglePalette = { [weak self] in self?.paletteCoordinator.togglePalette() }
            hotKeys.onRunCommand = { [weak self] id in self?.launcherCoordinator.runCommand(id) }
            hotKeys.onRunCustomCommand = { [weak self] id in
                self?.customCommandCoordinator.runCustomCommand(id: id)
            }
            hotKeys.onRunSystemAction = { [weak self] id in
                self?.systemActionCoordinator.runSystemAction(id: id)
            }
            hotKeys.onRunWindowCommand = { [weak self] id in
                self?.windowCommandCoordinator.runWindowCommand(id: id)
            }
            hotKeys.onRunWindowLayout = { [weak self] id in
                self?.windowLayoutCoordinator.runWindowLayout(id: id)
            }
            hotKeys.onEnterRoom = { [weak self] id in self?.roomCoordinator.enterRoom(id: id) }
            hotKeys.onRunCustomWindowSize = { [weak self] id in
                self?.windowCommandCoordinator.runCustomWindowSize(id: id)
            }
            hotKeys.onOpenQuicklink = { [weak self] id in
                self?.quicklinkCoordinator.openQuicklink(id: id)
            }
            hotKeys.onRunQuickAction = { [weak self] id in
                self?.quickActionCoordinator.run(id: id)
            }
            hotKeys.onRunAppleShortcut = { [weak self] id in
                self?.appleShortcutCoordinator.run(id: id)
            }
            hotKeys.onRunExtensionCommand = { [weak self] entryID in
                self?.extensionCoordinator.runExtensionCommand(entryID: entryID)
            }
            extensions.onDidUninstall = { [weak self] entryIDs in
                self?.extensionCoordinator.removeExtensionReferences(entryIDs: entryIDs)
            }
            appIndex.onScan = { [weak self] in
                guard let self else { return }
                hotKeys.removeAppBindings(where: appIndex.isUninstalled)
                // After the first scan, so the file's apps and panes have entries to match.
                if settings.settingsFileEnabled, settingsFile == nil {
                    startSettingsFile(importing: true)
                } else if let launcherSettingsFile {
                    reportSettingsFileIssues(launcherSettingsFile.applyInstalled())
                }
            }
            hotKeys.reservedBindingOwner = { [weak self] binding in
                guard let self else { return nil }
                if dictation.reservedBindings.contains(where: { $0.conflicts(with: binding) }) { return "Dictation" }
                return windowSwitcher.reservedBindings.contains(where: { $0.conflicts(with: binding) }) ? "Window Switcher" : nil
            }
            hotKeys.displayName = { [weak self] action in self?.hotKeyDisplayName(for: action) }
            hotKeys.allowsAction = { [weak self] action in
                guard let self else { return false }
                guard action.capability.map(settings.allows) ?? true else { return false }
                if case .windowCommand(let id) = action, SpaceDirection(id) != nil {
                    return settings.spacesEnabled || visibility.allowsHotKey(action)
                }
                guard visibility.allowsHotKey(action) else { return false }
                if action == .togglePalette { return settings.launcherEnabled }
                if action == .command(.clipboardHistory) {
                    return settings.clipboardEnabled || settings.snippetsEnabled
                }
                // A disabled feature drops its commands from the launcher; their shortcuts go too.
                guard case .command(let id) = action else { return true }
                return appIndex.isCommandEnabled(id)
            }
            SystemActionRunner.onAsyncFailure = { [weak self] id, failure in
                self?.systemActionCoordinator.presentSystemActionFailure(id: id, failure: failure)
            }
            hotKeys.start(
                customCommandIDs: Set(customCommands.commands.map(\.id)),
                quicklinkIDs: Set(quicklinks.quicklinks.map(\.id)),
                windowLayoutIDs: Set(windowLayouts.layouts.map(\.id)),
                windowRoomIDs: Set(rooms.rooms.map(\.id)),
                customWindowSizeIDs: Set(customWindowSizes.sizes.map(\.id)),
                quickActionIDs: Set(customQuickActions.actions.map(\.id)))
            applyFeatures()

            observeFeatureSwitches()

            // First launch binds no hotkey, so guide once; the marker is written at show-time.
            if !OnboardingState.hasOnboarded {
                OnboardingState.markShown()
                onboardingCoordinator.showOnboarding()
            }
        }
    }

    /// Clicking the Dock icon: raise whichever window is already open, else summon the launcher.
    func handleReopen() {
        if settingsCoordinator.focusExisting() { return }
        if aiChatCoordinator.focusExisting() { return }
        if onboardingCoordinator.focusExisting() { return }
        if updateCoordinator.focusExisting() { return }
        if supportCoordinator.focusExisting() { return }
        if customCommandCoordinator.focusOutputWindow() { return }
        if settings.launcherEnabled {
            paletteCoordinator.showPalette(mode: .launcher, restoreAnyMode: true)
        } else {
            settingsCoordinator.showSettings()
        }
    }

    func handleOpenURL(_ url: URL) {
        switch ExtensionOAuthSession.handleCallbackURL(url) {
        case .delivered:
            paletteCoordinator.showPalette(mode: .extensionCommand, restoreAnyMode: true)
            return
        case .expired:
            showMessage("Sign-in expired — run the command again", tone: .danger)
            return
        case .ignored:
            break
        }
        guard ExtensionDeepLink.claims(url) else { return }
        guard let link = ExtensionDeepLink.parse(url: url) else {
            paletteCoordinator.showPalette(mode: .launcher, restoreAnyMode: true)
            return
        }
        extensionCoordinator.runDeepLink(link)
    }

    /// The store-backed half of the conflict message; `HotKeyManager` names the catalogs itself.
    private func hotKeyDisplayName(for action: HotKeyAction) -> String? {
        switch action {
        case .app(let bundleID):
            return appIndex.apps.first { $0.kind == .application && $0.bundleID == bundleID }?.name
        case .settingsPane(let bundleID):
            return appIndex.apps.first { $0.kind == .systemSettings && $0.bundleID == bundleID }?
                .name
        case .customCommand(let id):
            return customCommands.command(id: id)?.name
        case .quicklink(let id):
            return quicklinks.quicklink(id: id)?.name
        case .quickAction(let id):
            return customQuickActions.action(id: id)?.name
        case .windowLayout(let id):
            return windowLayouts.layout(id: id)?.name
        case .windowRoom(let id):
            return rooms.room(id: id)?.name
        case .customWindowSize(let id):
            return customWindowSizes.size(id: id)?.name
        case .appleShortcut(let id):
            return appleShortcutCoordinator.name(of: id)
        case .extensionCommand(let entryID):
            return appIndex.apps.first { $0.kind == .extensionCommand && $0.id == entryID }?.name
        case .togglePalette, .command, .systemAction, .windowCommand:
            return nil
        }
    }

    func restart() {
        restartRequested = true
        NSApp.terminate(nil)
    }

    func flushNotesForTermination() async -> Bool {
        defer { restartRequested = false }
        await screenNotes.prepareForTermination()
        let dictationSaved = await dictation.prepareForTermination()
        let clipboardSaved = await clipboard.prepareForTermination()
        notifications.stop()
        await notifications.finishStopping()
        await notesCoordinator.prepareForTermination()
        guard dictationSaved && clipboardSaved else {
            dictation.apply()
            clipboard.apply()
            notifications.apply()
            await showNotice(title: "History could not be saved", message: "Ollie is still open. Free up disk space or check folder permissions, then try quitting again.", symbol: "exclamationmark.triangle", tone: .danger)
            return false
        }
        if restartRequested {
            do {
                try RelaunchRunner.relaunchAfterExit(Bundle.main.bundleURL)
            } catch {
                dictation.apply()
                clipboard.apply()
                notifications.apply()
                await showNotice(
                    title: "Ollie could not restart", message: error.localizedDescription,
                    symbol: "exclamationmark.triangle", tone: .danger)
                return false
            }
        }
        return true
    }

    func prepareForTermination() {
        compactMenu.stop()
        dictation.stop()
        spaces.stop()
        windowSwitcher.stop()
        clipboard.stop()
        typingSounds.stop()
        cameraCoordinator.stop()
        screenNotes.stop()
        customCommandCoordinator.stop()
        mediaImport.stop()
        notifications.stop()
        network.stop()
        launcherRefreshTask?.cancel()
        currencyRates.stop()
        settingsFile?.flush()
        windowLayoutCoordinator.prepareForTermination()
        roomCoordinator.prepareForTermination()
        inputSourceSwitcher.endSession()
        textInjector.prepareForTermination()
        aiChatCoordinator.stop()
        chatGPTSubscription.stop()
        mcpOAuth.stop()
        mcp.stop()
        installedAI.stop()
    }

    /// Only the tool whose own path or variables changed is checked again; the rest keep running.
    private func applyInstalledLaunches() {
        let revisions = aiSettings.launchRevisions
        let enabled =
            settings.aiEnabled
            ? aiSettings.enabledInstalledProviders : []
        for kind in InstalledAIKind.allCases where appliedLaunchRevisions[kind] != revisions[kind] {
            guard enabled.contains(kind) else { continue }
            if kind == .codex {
                chatGPTSubscription.stop()
                chatGPTSubscription.refresh()
            } else {
                installedAI.refresh(kind: kind)
            }
        }
        appliedLaunchRevisions = revisions
    }

    @discardableResult
    func applyInstalledAILifecycle() -> Task<Void, Never> {
        let enabledKinds =
            settings.aiEnabled
            ? aiSettings.enabledInstalledProviders : []
        var tasks: [Task<Void, Never>] = []
        if enabledKinds.contains(.codex) {
            tasks.append(
                chatGPTSubscription.phase == .idle
                    ? chatGPTSubscription.refresh()
                    : chatGPTSubscription.currentRefreshTask())
        } else {
            chatGPTSubscription.stop()
        }
        tasks.append(installedAI.ensure(enabledKinds: enabledKinds))
        return Task { for task in tasks { await task.value } }
    }

    /// Permissive guardrails: the text transformed is the reader's own, which `.default` refuses.
    func quickActionProvider(for action: QuickAction) throws -> any AIProvider {
        quickActionSettings.repairModel(
            against: aiSettings.connections, fallback: aiSettings.defaultModel)
        guard let selection = quickActionSettings.model(for: action) ?? aiSettings.defaultModel
        else {
            throw AIProviderError.unavailable("Choose a model in Settings \u{2192} Quick Actions.")
        }
        return try AIProviderFactory.make(
            selection: selection, settings: aiSettings, subscription: chatGPTSubscription,
            installedAI: installedAI,
            guardrails: .permissiveContentTransformations)
    }

    // MARK: - Feature switches

    private func applyNetworkEnabled() {
        if settings.networkEnabled { network.start() } else { network.stop() }
    }

    private func applyLauncherEnabled() {
        launcherRefreshTask?.cancel()
        compactMenu.applyVisibility()
        hotKeys.refreshRegistrations()
        guard settings.launcherEnabled else {
            cameraCoordinator.stop()
            customCommandCoordinator.stopUnavailableRuns()
            currencyRates.stop()
            if paletteCoordinator.isShowing(.launcher) {
                paletteCoordinator.hidePalette(restoreFocus: false)
            }
            appIndex.clearDiscoveredApps()
            return
        }
        currencyRates.start()
        launcherRefreshTask = Task { [weak self] in await self?.appIndex.refresh() }
    }

    private func applyFeatures() {
        let next = settings.featureAvailability
        let previous = appliedFeatures
        appliedFeatures = next
        let changed: (FeatureCapability) -> Bool = { previous?.allows($0) != next.allows($0) }
        if changed(.feature(.launcher)) { applyLauncherEnabled() }
        if changed(.feature(.clipboard)) || changed(.feature(.snippets)) { clipboard.apply() }
        if changed(.feature(.dictation)) { dictation.apply() }
        if changed(.feature(.windowSwitcher)) { windowSwitcher.apply() }
        if changed(.feature(.spaces)) { spaces.apply() }
        if changed(.feature(.screenNotes)) {
            screenNotes.apply()
        }
        if changed(.screenExplanation) {
            screenNotes.apply()
            appIndex.setCommandsVisible([.explainScreen], next.allows(.screenExplanation))
        }
        if changed(.feature(.typingSounds)) { typingSounds.apply() }
        if changed(.feature(.network)) { applyNetworkEnabled() }
        if changed(.feature(.notifications)) { notifications.apply() }
        if changed(.feature(.mediaImport)) { mediaImport.apply() }
        if changed(.feature(.ai)) { aiChatCoordinator.applyEnabled() }
        if changed(.quickActions) { quickActionCoordinator.applyEnabled() }
        if changed(.mcp) { mcpCoordinator.applyEnabled() }
        if changed(.fileSearch) { fileSearchCoordinator.applyEnabled() }
        if changed(.navigation) { menuSearchCoordinator.applyEnabled() }
        if changed(.notes) {
            if !next.allows(.notes) { notesFolderTask?.cancel() } else { applyNotesFolder() }
            notesCoordinator.applyEnabled()
        }
        if changed(.calendar) { calendarCoordinator.applyEnabled() }
        if changed(.extensions) { extensionCoordinator.applyEnabled() }
        if changed(.customCommands) { customCommandCoordinator.applyCustomCommandsPresence() }
        if changed(.quicklinks) { quicklinkCoordinator.applyQuicklinksPresence() }
        if changed(.appleShortcuts) { appleShortcutCoordinator.applyPresence() }
        if changed(.windowManagement) {
            applyWindowCommandsPresence()
            customWindowSizeCoordinator.applyCustomWindowSizesPresence()
            windowLayoutCoordinator.applyWindowLayoutsPresence()
            roomCoordinator.applyEnabled()
        }
        if !next.allows(palette.mode.capability) {
            paletteCoordinator.hidePalette(restoreFocus: false)
        }
        hotKeys.refreshRegistrations()
        compactMenu.applyVisibility()
    }

    private func observeFeatureSwitches() {
        track({ _ = $0.featureAvailability }, reproject: { $0.applyFeatures() })
        track({ _ = $0.spacesTransitionSpeed }, reproject: {
            $0.spaces.apply()
            $0.hotKeys.refreshRegistrations()
        })
        track(dictation.settings, { _ = $0.shortcuts; _ = $0.historyLimit; _ = $0.deepgramLanguage }, reproject: { $0.dictation.applySettings() })
        track(dictation.session, { _ = $0.recordingPhase }, reproject: {
            $0.typingSounds.isRecording = $0.dictation.session.recordingPhase != .idle
            $0.clipboard.isRecording = $0.dictation.session.recordingPhase != .idle
        })
        track({
            _ = $0.switcherCommandTab; _ = $0.switcherCommandBacktick; _ = $0.switcherWindowSource
            _ = $0.switcherMinimizedMode; _ = $0.switcherHiddenMode; _ = $0.switcherAppsWithoutWindowsMode
            _ = $0.switcherImmediatePreview
        }, reproject: { $0.windowSwitcher.apply() })
        track(hotKeys, { _ = $0.revision }, reproject: { $0.windowSwitcher.apply(); $0.dictation.apply() })
        track({ _ = $0.clipboardHistoryDays }, reproject: { $0.clipboard.apply() })
        track({ _ = $0.showInMenuBar }, reproject: { $0.compactMenu.applyVisibility() })
        track({
            _ = $0.typingSoundProfile
            _ = $0.typingSoundVolume
            _ = $0.typingSoundDownVolume
            _ = $0.typingSoundUpVolume
            _ = $0.typingMouseEnabled
            _ = $0.typingMouseVolume
        }, reproject: { $0.typingSounds.apply() })
        track(hotKeys, { _ = $0.recordingAction }, reproject: {
            $0.dictation.isCapturingShortcut = $0.hotKeys.recordingAction != nil
            $0.windowSwitcher.isCapturingShortcut = $0.hotKeys.recordingAction != nil
            $0.clipboard.isCapturingShortcut = $0.hotKeys.recordingAction != nil
            $0.typingSounds.isCapturingShortcut = $0.hotKeys.recordingAction != nil
        })
        track(
            { _ = $0.automaticallyCheckForUpdates },
            reproject: { $0.updateCoordinator.applyAutomaticChecking() })
        track(
            {
                _ = $0.windowManagementShowInLauncher
            },
            reproject: {
                $0.applyWindowCommandsPresence()
                $0.hotKeys.refreshRegistrations()
                $0.customWindowSizeCoordinator.applyCustomWindowSizesPresence()
            })
        track(
            {
                _ = $0.windowLayoutsShowInLauncher
            }, reproject: { $0.windowLayoutCoordinator.applyWindowLayoutsPresence() })
        track(
            {
                _ = $0.windowRoomsShowInLauncher
            }, reproject: { $0.roomCoordinator.applyEnabled() })
        track(
            {
                _ = $0.customCommandsShowInLauncher
            }, reproject: { $0.customCommandCoordinator.applyCustomCommandsPresence() })
        track(
            {
                _ = $0.quicklinksShowInLauncher
            }, reproject: { $0.quicklinkCoordinator.applyQuicklinksPresence() })


        track(
            {
                _ = $0.calendarShowInLauncher
                _ = $0.calendarLauncherLimit
            }, reproject: { $0.calendarCoordinator.publishEntries() })
        track(
            { _ = $0.calendarSpan },
            reproject: { $0.calendarCoordinator.applySpan() })
        track(
            {
                _ = $0.autoJoinMeetings
                _ = $0.menuBarEvents
                _ = $0.calendarMenuBarDisplay
                _ = $0.menuBarLinkedEventsOnly
                _ = $0.hideCurrentEvent
            }, reproject: { $0.calendarCoordinator.applyClock() })
        track(
            {
                _ = $0.fileSearchScopes
                _ = $0.fileSearchIgnorePatterns
            }, reproject: { $0.fileSearchCoordinator.applyPolicy() })

        // Not a feature switch, but the same re-projection: a combo has the chord's ⇧ bit baked in.

        track({ _ = $0.appearance }, reproject: { $0.applyAppearance() })
        track({ _ = $0.paletteDensity }, reproject: { $0.paletteCoordinator.syncPaletteSize() })
        track({ _ = $0.interfaceSize }, reproject: { $0.windowController.applyInterfaceSize() })
        // Settings panes did these on change; settings.json can change them with no pane open.

        track(aiSettings, { _ = $0.retention }, reproject: { $0.aiChatCoordinator.applyRetention() })
        track(aiSettings, { _ = $0.launchRevisions }, reproject: { $0.applyInstalledLaunches() })
        track(
            { _ = $0.extensionsShowInLauncher },
            reproject: { $0.extensionCoordinator.applyExtensionsLauncherPresence() })

        track({ _ = $0.notesFolder }, reproject: { $0.applyNotesFolder() })
        trackChatRoute()
    }

    /// `.system` resolves to `nil`, so AppKit follows macOS with nothing polling.
    private func applyAppearance() {
        NSApp.appearance = settings.appearance.nsAppearance
    }

    /// IconCache is told here, not from `applyAppearance()`, which never fires under `.system`.
    private func observeEffectiveAppearance() {
        // Synchronous on main, so no row can cache a tile under the outgoing appearance's key.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial]) { app, _ in
            MainActor.assumeIsolated { IconCache.setDarkSurface(app.effectiveAppearance.isDark) }
        }
    }

    private func track(
        _ reads: @escaping @Sendable @MainActor (AppSettings) -> Void,
        reproject: @escaping @Sendable @MainActor (AppCore) -> Void
    ) {
        track(settings, reads, reproject: reproject)
    }

    /// Fires synchronously on main before the write lands, so the task re-arms and re-reads.
    private func track<Store: AnyObject & Sendable>(
        _ store: Store,
        _ reads: @escaping @Sendable @MainActor (Store) -> Void,
        reproject: @escaping @Sendable @MainActor (AppCore) -> Void
    ) {
        withObservationTracking {
            reads(store)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.track(store, reads, reproject: reproject)
                reproject(self)
            }
        }
    }

    /// A chat route that runs its own MCP client decides which servers Ollie runs itself.
    private func trackChatRoute() {
        let runsOwnTools = withObservationTracking {
            aiChatCoordinator.everyChatRunsItsOwnTools
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackChatRoute() }
        }
        // Re-read on every streaming flush, so only a changed verdict reaches the servers.
        defer { chatsRunTheirOwnTools = runsOwnTools }
        guard let previous = chatsRunTheirOwnTools, previous != runsOwnTools else { return }
        mcpCoordinator.applyEnabled()
    }

    private func applyNotesFolder() {
        guard settings.allows(.notes) else { return }
        notesFolderTask?.cancel()
        let previous = notesFolderTask
        let repository = Self.notesRepository(for: settings)
        notesFolderTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, settings.allows(.notes) else { return }
            await notesStore.relocate(to: repository)
        }
    }

    private static func notesRepository(for settings: AppSettings) -> NotesRepository {
        NotesRepository(notesDirectory: AppPaths.contentFolder(settings.notesFolder, named: "Notes"))
    }

    private func applyWindowCommandsPresence() {
        let visible = settings.allows(.windowManagement) && settings.windowManagementShowInLauncher
        appIndex.setWindowCommandsVisible(visible)
    }

    // MARK: - Settings file

    /// Mirrors settings into settings.json from now on; `importing` applies the file's own first.

    func startSettingsFile(importing: Bool) {
        guard settingsFile == nil else { return }
        let shortcuts = HotKeySettingsFile(hotKeys: hotKeys)
        let launcher = LauncherSettingsFile(
            appIndex: appIndex, aliases: aliases, visibility: visibility, shortcuts: shortcuts)
        let file = SettingsFileRepository(
            fileURL: AppPaths.settingsFile(),
            bindings: SettingsFileSchema.bindings(
                settings: settings, ai: aiSettings, dictation: dictation.settings,
                mediaImport: mediaImport.state.settingsStore, quickActions: quickActionSettings,
                shortcuts: shortcuts, launcher: launcher,
                windowManagement: WindowManagementSettingsFile(
                    sizes: customWindowSizes, layouts: windowLayouts, rooms: rooms, aliases: aliases,
                    shortcuts: shortcuts)),
            commit: shortcuts.commit)
        file.onIssues = { [weak self] issues in self?.reportSettingsFileIssues(issues) }
        settingsFile = file
        launcherSettingsFile = launcher
        settings.settingsFileEnabled = true
        file.start(importing: importing)
    }

    /// Stops the mirror; the file stays on disk as last written.
    func stopSettingsFile() {
        settingsFile?.flush()
        settingsFile = nil
        launcherSettingsFile = nil
        settings.settingsFileEnabled = false
    }

    private func reportSettingsFileIssues(_ issues: [SettingsFileIssue]) {
        guard let summary = SettingsFileIssue.summary(issues) else { return }
        showMessage(summary, tone: .danger)
    }

    // MARK: - Interruption

    /// What the app is in the middle of; the update prompt and the support reminder both ask first.
    var currentActivity: UpdateActivity {
        UpdateActivity(
            isDeliveringText: textInjector.isDelivering,
            isRunningExtension: extensions.running != nil,
            isUninstalling: uninstall.isTrashing,
            isRecordingHotKey: hotKeys.recordingAction != nil,
            isShowingDialog: isShowingDialog,
            isPaletteVisible: paletteCoordinator.isVisible || screenNotes.isActive,
            isImporting: mediaImport.state.isImporting, isRecording: dictation.isBusy)
    }

    /// Whether a window may take focus without interrupting something the user started.
    var canInterruptUser: Bool { UpdateReadiness.evaluate(currentActivity) == nil }

    // MARK: - Dialogs, routed here so `dialogs` stays the single owner

    func showNotice(title: String, message: String, symbol: String, tone: DialogTone) async {
        await dialogs.notice(title: title, message: message, symbol: symbol, tone: tone)
    }

    /// `tone` styles the glyph, `confirmRole` the button; separate on purpose.
    func confirm(
        title: String, message: String?, symbol: String?, confirmTitle: String,
        tone: DialogTone = .danger, confirmRole: DialogAction.Role = .destructive,
        dismissTitle: String = "Cancel"
    ) async -> Bool {
        await dialogs.confirm(
            title: title, message: message, symbol: symbol, tone: tone, confirmTitle: confirmTitle,
            confirmRole: confirmRole, dismissTitle: dismissTitle)
    }

    /// A question with more than two answers; the returned index is into `options`.
    func choose(
        title: String, message: String?, symbol: String?, options: [DialogAction],
        defaultIndex: Int, tone: DialogTone = .neutral
    ) async -> Int {
        await dialogs.choose(
            title: title, message: message, symbol: symbol, tone: tone, options: options,
            defaultIndex: defaultIndex)
    }

    /// A failure with one usable second option; `true` when the user takes it.
    func reportFailure(
        title: String, message: String, symbol: String, recovery: String?
    ) async
        -> Bool
    {
        await dialogs.reportFailure(
            title: title, message: message, symbol: symbol, recovery: recovery)
    }

    /// The transient success/info pill, so `messageHUD` stays single-owned alongside `dialogs`.
    func showMessage(_ message: String, tone: DialogTone = .success) {
        messageHUD.show(message: message, tone: tone)
    }

    /// The same pill with a spinner, for work the reader started and cannot otherwise see running.
    func showProgress(_ message: String, onCancel: (() -> Void)? = nil) {
        messageHUD.showProgress(message: message, onCancel: onCancel)
    }

    func hideProgress() {
        messageHUD.dismiss()
    }

    /// The volume slider, so `dialogs` stays the single owner of every prompt in the app.
    func pickVolume(current: Float32) async -> Float32? {
        await dialogs.pickVolume(current: current)
    }

    /// The new-event prompt, for the same reason.
    func createEvent() async -> EventDraft? {
        await dialogs.createEvent()
    }

}
