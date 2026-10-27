# Ollie integration

Ollie is the unified native app. Its folder, source directory, Xcode project, target, scheme,
repository, URL scheme (`ollie://`), and backup format name (`.ollie`) use Ollie.
The stable bundle identifier (`nl.bentjes.fredie`) and its channel suffixes remain the internal
system identity. Existing defaults, Application Support and caches, Keychain services, permissions,
login registration, and the `~/.config/fredie/settings.json` mirror retain their data identity.
Debug and the rendering harness have separate bundle identifiers and data directories. Mailie is excluded.

## Features and ownership

`AppCore` owns ClipboardCoordinator, DictationCoordinator, WindowSwitcherCoordinator,
TypingSoundsCoordinator, MediaImportCoordinator, NotificationsCoordinator, NetworkCoordinator,
SpacesCoordinator, ScreenNoteCoordinator, and CompactMenuController. The existing launcher and AI remain.
New capture and monitoring capabilities start disabled and cannot be enabled by a settings import.
Each switch controls its service lifecycle; the shared HealthTicker recovers input monitors after
permissions change. Synthetic input carries the host Paster marker so it cannot trigger sounds or
another input handler. Dictation temporarily silences typing sounds and snippet expansion.

Snippet auto-expansion consumes the completing key inside the event-tap callback. TextInjector
first tries confirmed AX replacement of the already-forwarded trigger range. When AX
is unavailable, tagged backspaces and scalar-safe Unicode chunks use that callback's proxy. Newline
and tab chunks are isolated from adjacent text. Deferred suggestion refreshes never insert text.
Tab and Return consume the selection key and use the same replacement path. See
[Inline snippets](features/launcher.md#inline-snippets) for boundaries, preview and placement.

`FeatureAvailability` is the shared rule for feature ownership. Settings panes, palette modes,
commands, shortcut registration and action dispatch use it. Launcher owns its saved child options;
Quick Actions and MCP require AI. Turning a parent off preserves those options without running them.
Clipboard and Snippets share their panel but remain independent; Spaces shortcuts do not require
Launcher. Screen Notes has an independent switch and requires Dictation for narrated screenshots.
It hands speech back without auto-paste and copies annotated PNGs plus a note for pasting into AI.
AppCore compares effective capabilities and applies only the changed coordinators.

Every disable rejects new actions, removes input and background listeners, cancels pending work,
closes feature surfaces and invalidates stale callbacks. Coordinators keep their own cleanup.
Asynchronous shutdown drains before a restart: notification streams, extension runtimes, media
imports, dictation capture and camera configuration cannot race their replacement. Completed work
may finish its durable bookkeeping; room cleanup returns parked windows and hidden apps. Saved data,
provider keys and preferences remain intact. Shared dialogs dismiss only their cancelled owner's
request. Settings and the primary status item remain available with every feature off.

The window switcher includes Ollie's own standard windows, including Settings, while they are open.
Closing the last app window returns Ollie to accessory mode and removes it from the switcher.
Accessibility reads and actions targeting Ollie run on the main thread because AppKit handles them
in process; access to other apps remains on the serialized background workers.

Spaces integrates Strafe's trackpad interception, desktop boundary prediction, and Instant/Quick/Smooth
transition presets. Its master switch starts off; Accessibility is reused and retried by HealthTicker.
Only gesture/Dock events enter its tap. Mission Control gestures and synthetic input pass through.
Previous/Next Space shortcuts use the existing window-command bindings, also exposed in Spaces and
Shortcuts, and work independently of Launcher. Bindings are left unassigned until recorded.
The shared SpaceSwitcher retains Ollie's gesture encoding and handles keyboard and trackpad requests.
Boundary state is display-specific, resets on Space changes, expires after missing notifications, and
rejects changed desktop layouts. Animated gestures serialize and close when disabled.
Speed and shortcuts mirror through settings.json; importing cannot enable swipe interception.
Strafe's source and upstream license notices are bundled in NOTICE.md.

The original shells, status items, app delegates, and settings windows were not imported. Native
settings use the feature coordinator environments. Features is the default settings page and owns
all master switches. Disabled feature panes and their search results are hidden; navigation history
drops them and stale links return to Features. Launcher owns the Applications and Emoji panes.
Clipboard uses the palette’s floating two-column mode; media import retains its task window; dictation retains its recording overlay. The compact menu has icon actions, live
recording/import state, notifications, network usage, and settings. Shortcut information lives in
settings and tooltips, with no menu row dedicated to displaying a shortcut.

The copied speech transports and audio capture keep serial queues at callback boundaries to retain
FIFO PCM delivery and websocket ordering. App lifecycle, history writing, UI scheduling and shutdown
use Swift concurrency. There is no extra actor or ObservableObject state model.

## Data and privacy

New files live beneath the bundle-specific Application Support directory: Clipboard, Dictation,
MediaImport, Network, and the notification inbox. Dictation credentials and private notification
topics live in bundle-specific Keychain services. Transcription requests use private ephemeral
sessions with no URL cache. Retention and history operations keep recordings inside Ollie’s managed
directory. History payloads are written with owner-only permissions.

Dictation enhancement prompts select OpenRouter, Celeris, or Mercury and their model independently.
Mercury calls Inception's `https://api.inceptionlabs.ai/v1/chat/completions` directly, defaults to
`mercury-3`, and uses `reasoning_effort: instant` for minimum deliberation latency. Its API key uses
the same bundle-specific Keychain service as the other dictation providers and is excluded from
settings files and backups.

There is no standalone-app detection, coexistence gating, or old-app import UI. The requested local
settings transfer was performed once outside the product, preserving original app preferences and
backing up Ollie's previous preferences. It verified 34 settings, six dictation credentials and two
notification topics. Settings and private topic names stay in Ollie's own stores; the old apps are
not consulted during startup or operation. Original histories and media files were not moved.
Clipboard content paths reject traversal and symlinks.
Disabling Clipboard cancels its pending copies, pastes and OCR; Snippets has independent cancellation.
A shared panel switches to the remaining enabled feature, or closes when both are disabled.
Search refreshes preserve the latest selection by item identity. Delayed paste requires the original
clipboard change count and active target before posting keystrokes.
Access flags, login-item registration, and provider credentials are not carried by settings.json.

Dictation clipboard restoration requires both successful insertion verification and an unchanged
clipboard change token. Starting another operation or disabling dictation cancels pending restoration.
Shutdown waits for capture cancellation, queued history writes. Failed history
flushes keep the app open instead of silently losing pending history.
Cancelled dictation deletes managed raw recordings only when no history entry adopted them, including
cancellation during enhancement. Paste or insertion-verification failure preserves adopted recordings.

## Scope and release

Network includes Nettie’s existing process traffic monitor, per-app usage, and saved daily totals.
Its collector runs under a supervisor tied to a private pipe from Ollie. Stopping monitoring or
losing Ollie's process closes that pipe; the supervisor kills and reaps `nettop` before exiting.
This prevents collectors from spinning on a disconnected terminal after a crash or relaunch.
It does not enforce network rules. The configured Personal Team cannot provision the required Network
Extension capability; settings accurately show monitoring and inactive protection.

The signed local release installs `/Applications/Ollie.app` after verifying the replacement. A failed open restores the previous installation. An enabled
login item is re-registered after a bundle move. The updater checks the existing repository, signing
identity and bundle identifier, plus the unified-app marker, so an old launcher-only build cannot
replace Ollie.

Opus round 1 supplied the integration review in `ollie-opus-consult-r1.md`. Rounds 2 and 3 returned
Claude API rate-limit errors and provided no review. The primary agent implemented and tested the code.
