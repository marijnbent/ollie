# Testing and verification

How to check that a change holds up. Ollie has no XCTest target: the automated half
is a set of standalone harnesses, and the manual half is the sweep at the bottom of this file.

## Definition of done

The mechanical bar, in one place so it cannot drift. All five pass before a change is finished.

| Check | Command |
| --- | --- |
| Relevant harnesses | `./scripts/run-tests.sh <harness>`; full suite only when broader coverage is warranted |
| Lint | `./scripts/lint.sh` |
| Pure-layer purity | `grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Ollie/Features/*/Model/` |
| A clean build | `xcodebuild … -configuration Debug CODE_SIGNING_ALLOWED=NO`, zero **new** warnings |
| Docs still true | any doc your change made wrong, fixed in the same commit |

There is no CI: every item is on you, run locally. CodeRabbit reviews each PR, but it is a reviewer,
not a gate. Each is expanded below; the manual sweep at the end of this file is the sixth, judged by
what you touched.

Keep checks proportional to the change and stop once there is enough evidence. Ask before running
tests that open or activate windows, move focus, send input, or may trigger macOS permission prompts.
This also applies to a full-suite run and to separate test apps on Marijn's live desktop.
A requested release authorizes restarting Ollie, not additional interactive tests.

## The harnesses

```sh
./scripts/run-tests.sh              # all of them
./scripts/run-tests.sh calc-test    # just one, while iterating
```

The suite runs four harnesses at a time by default to reduce CPU usage. `OLLIE_TEST_JOBS` overrides
that limit; `OLLIE_TEST_JOBS=1` runs one at a time. Each result is numbered
against the total and shows its run and compile time, a quiet stretch names the harnesses still running, and a harness that runs longer
than `OLLIE_TEST_TIMEOUT` seconds (default 300) is killed and reported as timed out. Parallelism is safe
because each harness already roots its scratch state somewhere of its own — a UUID-suffixed
`temporaryDirectory`, a `UserDefaults(suiteName:)`, or `NSPasteboard.withUniqueName()` — and a new
harness must keep doing that rather than reach for a fixed path.

Two consequences worth knowing. Status lines arrive in **completion order**, not the order the `run`
lines are written; and a failing harness's compiler diagnostics or assertion output are replayed
together at the bottom, under its name, rather than streamed where they happened. That is deliberate:
a compiler diagnostic is far longer than `PIPE_BUF`, so eleven workers streaming at once would
interleave into nonsense.

A `run` line takes two optional markers before the harness name. `-O` compiles that harness optimised,
which is worth it only where the run dominates the compile — `raycast-test` spends 47 seconds in
scrypt at `-Onone` and one second at `-O`. `slow` dispatches it in the first wave, so the longest
harnesses are not still running after everything else has finished.

`settings-history-test` also runs with `-O`: the feature visibility filter previously passed in Debug
but crashed when opening Settings in Release. Its existing visibility assertions reproduce that crash
under optimization and verify that disabled feature panes stay hidden.

The script is the **only** place the harness set is written down. Nothing runs it for you, so run it
before you open a PR. Adding a harness means adding one `run` line.

Each harness compiles the **shipped sources** it guards rather than a copy of them, which is what makes
the pure-layer boundary real: a harness that stops *compiling* means AppKit or SwiftUI has leaked into a
`Model/` folder, or an effect has leaked into a decision. That is a more common failure than a broken
assertion, and it is the more important one.

Harnesses run against the real system. Use private pasteboards and temporary files so they never
change the user's clipboard or app data. `notes-editor-test` drives the native selection read/write
primitives through `NSPasteboard.withUniqueName()`.

Never join a compile to its run with `&&` in a `set -e` script. `set -e` is specified to ignore a
failing command in a non-final AND-OR list member, so `swiftc … && /tmp/x` swallows a compile error and
the script sails on. CI reported success over a harness that had not compiled for twenty-five phases
because of exactly this; `run-tests.sh` keeps the two steps separate and records both kinds of failure.

### What to run when

If a change touches anything in the right column, the harness on the left is mandatory.

| Harness | Guards |
| --- | --- |
| `fuzz-test` | `Launcher/Model/LauncherMatch.swift`, `LauncherOrder.swift`, `LauncherSuggestions.swift`, `EntryNaming.swift`, `ScriptRomanization.swift`, `SearchRelevance.swift`, `LauncherRankingStore.swift` — **a new ranking complaint is a new case in its `denseIndex`** |
| `file-search-test` | `FileSearch/Model/`, plus the shared `FuzzyMatch` scorer |
| `file-search-session-test` | serialized query execution, debounce coalescing and cancellation |
| `menu-search-test` | `MenuSearch/Model/` decisions, `MenuSearch/Service/` session filtering, the shared `FuzzyMatch` scorer |
| `action-menu-search-test` | Action-menu query normalization and shared fuzzy matching |
| `ranking-test` | `Launcher/Model/LauncherRankingStore.swift` |
| `scopes-test` | `Launcher/Model/SearchScopes.swift` |
| `app-name-test` | `Platform/AppDisplayName.swift` — every path that names a scanned bundle |
| `calc-test` | all of `Calculator/Model/` |
| `calendar-test` | all of `Calendar/Model/` — link detection, the join window, the day buckets |
| `emoji-test` | `Emoji/Model/EmojiCatalog.swift`, `EmojiGridGeometry.swift`, the generated data and keyword packs |
| `emoji-search-test` | `Emoji/Service/EmojiIndex.swift`, `FrequentEmojiStore.swift`, `scripts/gen-emoji.js`'s keyword format, multilingual search |
| `palette-navigation-test` | `Palette/PaletteState.swift`'s screen motions — `prepare`, `replace`, `push`, `pop` |
| `palette-selection-test` | `Features/PaletteRowIndex.swift` |
| `clipboard-coordinator-test` | Feature-specific operation cancellation, pending OCR completion, editor cancellation, and selection during asynchronous refreshes |
| `snippet-expansion-test` | Actual snippet key handler and native text editing: completing-key suppression, single-paste replacement, buffered typing, preceding text, ambiguous prefixes, backspace, and generated input |
| `interface-size-test` | `DesignSystem/InterfaceMetrics.swift`, `Features/Settings/InterfaceSize.swift`, `Extensions/Model/ExtensionFormMetrics.swift` |
| `palette-surface-test` | Unified launcher and clipboard sizing, stable anchors across modes, and continuous panel geometry |
| `palette-placement-test` | `DesignSystem/Theme.swift`, `Palette/PalettePlacement.swift` |
| `screen-ink-test` | `ScreenNotes/Model/` — ink expiry, undo, geometry, compositing and screenshot bounds |
| `screen-note-clipboard-test` | Text, separate PNGs and note-file output on a private pasteboard |
| `hotkey-test` | `HotKeys/Model/DoubleTapModifier.swift`, `DoubleTapDetector.swift`, `ModifierKey.swift`, `ModifierKeyDetector.swift`, `HotKeyBinding.swift`, `HotKeySpelling.swift`, `HotKeyAction.swift`, `Service/KeyShortcut.swift`, and the command→action mapping in `Launcher/Model/CommandID.swift` |
| `fallback-test` | `Launcher/Model/Fallback.swift`, plus the `CommandID` and `Quicklink` ids it is built from |
| `dictionary-test` | `Dictionary/Model/DictionaryEntry.swift`, `DictionaryMarkup.swift` — a real XHTML record and the plain-text fallback, read into page blocks |
| `callout-test` | `DesignSystem/Theme.swift`, `HotKeys/UI/CalloutPlacement.swift` |
| `system-action-test` | `SystemActions/Model/SystemAction.swift` |
| `microphone-mute-test` | Native input mute, delayed confirmation, device switches and failures; injected CoreAudio calls only |
| `volume-test` | `SystemActions/Model/VolumeLevel.swift` |
| `window-command-test` | `WindowManagement/WindowCommand.swift`, `WindowPlacementEngine.swift`, `WindowActionMemory.swift` |
| `window-layout-test` | `WindowManagement/Model/WindowLayout*.swift` and `CustomWindowSize*.swift` — the layout record, its geometry and its inverse, the plan and the store; custom sizes' units, frames and store |
| `window-room-test` | `WindowManagement/Model/Room*.swift` — every room layout and its minimum sizes, the grid, arrangement reading, window matching, parking, the plan, Tab's choices and the three stores |
| `custom-command-test` | `CustomCommands/Model/CustomCommand.swift`, `Service/ShellCommandRunner.swift` |
| `uninstall-test` | all five pure files in `Uninstall/Model/` |
| `quicklink-template-test` | Current clipboard and selection expansion, URL encoding, arguments, dates and UUIDs |
| `snippet-expansion-test` | Event-tap consumption and ordering, long multiline insertion, trigger boundaries, title matching, primary-screen AX conversion, popup clamping, deferred opening, cancellation, ranking and keys, and inline snippet drafts |
| `text-injection-test` | Private pasteboard restoration and ownership, single-paste inline delivery, prepared and stale clipboard snapshots, Unicode delivery chunks, replacement confirmation and queue ordering |
| `quicklink-test` | all of `Quicklinks/Model/` |
| `quicklink-coordinator-test` | Quicklink opening and inline argument focus — missing selection, manual input, clipboard fallback and default-app overrides; no platform effects |
| `apple-shortcut-test` | all of `AppleShortcuts/Model/` — the `shortcuts list` parser and entry ids |
| `notes-test` | all of `Notes/Model/` and `Notes/Service/`, including the Markdown parser, edit plans and reveal policy, plus the real fuzzy matcher and signposts |
| `notes-editor-test` | the Notes editor, rendered and literal, with real TextKit 2 and AppKit editing objects: styling, reveal, layout fragments, keys, chords, checkboxes and links |
| `raycast-test` | `Backup/Service/RaycastDecoder.swift`, `Scrypt.swift`, `Platform/Compression/Zlib.swift` |
| `symbols-test` | `Extensions/Service/SymbolCatalog.swift`, against this machine's CoreGlyphs |
| `ext-store-test` | `Extensions/Model/` — GitHub source parsing and URLs, the store and Git tree parsers |
| `ext-refresh-test` | `Extensions/Model/ExtensionRefreshPolicy.swift` — interval parsing, due dates, backoff, subtitle fallback, indicator state, Refresh Now refusals |
| `ext-version-test` | `Extensions/Service/ExtensionVersionStore.swift` — what an update check reports, adopts and forgets |
| `ext-metadata-test` | `Extensions/Service/ExtensionCommandMetadataStore.swift` — round-trip, failure runs, uninstall |
| `ext-test` | the extension runtime and native menu-bar lifecycle — boots shipped sources in JavaScriptCore; menu tests cover restoration, refresh serialization, actions and teardown; fetch tests cover HTTP connection cleanup, cancellation and request isolation |
| `ext-icon-test` | `Extensions/Service/ExtensionIconCache.swift` — artwork sizing and its fallback |
| `icon-cache-test` | `Platform/Images/IconCache.swift` — row sizing at 1×/2×, warm reuse, stamp and style invalidation, bitmap release, fitted geometry across all 256 alpha values, and that a row icon draws identically to the 96px one |
| `entry-icon-test` | `EntryIcon` — that each case draws, caches and prints apart from the others, and that a moved `FileIconStamp` retires the bitmap decoded before it |
| `text-diff-test` | `QuickActions/Model/TextDiffEngine.swift` — exact chunks, Unicode, ties, token-cap boundaries and fast paths |
| `settings-backup-test` | `Settings/AppSettingsKey.swift`, `Backup/Model/SettingsBackupCoverage.swift` |
| `settings-file-test` | `Settings/Model/` and `Settings/Service/` — key paths, value tokens, the printer and parser, and the repository's import, replace, save, reload and symlink handling on a scratch folder |
| `window-file-test` | `WindowManagement/Model/WindowManagementFileFormat.swift` — command shortcuts, custom sizes, layouts and rooms as settings.json spells them, hand edits and bad records |
| `launcher-settings-file-test` | Launcher settings application — invalid records, partial edits, deferred bundles, shortcut moves and records outside search scopes; isolated preferences and in-memory scan/Carbon effects |
| `backup-archive-test` | all of `Backup/Model/`, plus `Backup/Service/BackupStaging.swift` |
| `updates-test` | `Updates/Model/` — version precedence, channel filtering, install route, readiness |
| `update-check-test` | `UpdateCheckStore` — stopping, in-flight cancellation, cached prompt suppression, restart and independent manual checking |
| `support-test` | `Support/Model/` — when the support reminder comes due, and a clock moved backwards |
| `mcp-test` | `MCP/Model/` and `MCPSettingsStore` — JSON-RPC framing, handles, tool names, output flattening, trust, `@server` addressing, the shape a vendor CLI is handed, and which servers Ollie leaves to that CLI |
| `mcp-stdio-test` | `MCP/Service/` against a stub server — handshake, listing, calling, and every way one can go away |
| `mcp-oauth-test` | OAuth parsing, RFC 7636 PKCE, discovery and resource binding, loopback callback validation/cancellation, dynamic registration, supplied client credentials and their token-endpoint authentication, Keychain token rotation, concurrent refresh, the wider margin for a token lent to a CLI, redirects and one-retry 401 handling |

The subprocess harnesses bring their own servers: `Tests/ai-fixtures/codex-stub.js`
and `mcp-stub.js`, each copied into a scratch directory and put in front of PATH so the locator finds
it the way it would find a real one. Both read fd 0 synchronously rather than through a stream —
`codex-stub.js` stalls mid-turn on purpose, and an event loop would read the next line while it is
still holding — and both write with `fs.writeSync`, so a reply is on the pipe before a mode that
exits does. `installed-cli-stub.js` reads the same way for the one turn shape that answers back:
Claude's consent channel is a reply on stdin in the middle of a turn, so the stub has to be sitting
on the pipe when it arrives.

`mcp-oauth-test` starts `Tests/ai-fixtures/mcp-oauth-stub.js` on `127.0.0.1:4963` and tests the
single-use callback on `127.0.0.1:4962`. Both ports must be free; the harness never chooses another
port. Its Keychain scope is unique to each run and removed on completion.

A harness that passed before a change passes after it. There is no "I'll fix it next commit" and no
commenting out a case. If a change genuinely invalidates an assertion, the assertion is rewritten in the
same commit with the reason in the message.

### Purity checks

The layering rule reduces to one grep, and it must return nothing:

```sh
grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Ollie/Features/*/Model/
```

Beyond the imports, the injected-environment half is not mechanically checkable, so it is worth an eye
when touching a pure file:

- `Calculator/Model/` still takes its clock via `now`/`calendar`, its rates via `rates` and its
  separators via `format`
- `Uninstall/Model/`'s deciding half still receives directory **names** and a `PathFacts`, never URLs
- `HotKeys/Model/DoubleTap*` still take the clock as a parameter
- `WindowManagement/Model/` still touches no `NSScreen` and makes no AX call, layouts included
- `Features/PaletteRowIndex.swift` still imports Foundation alone, despite living under `Features/`
- `Quicklinks/Model/` is still handed the home directory rather than reading it
- `FileSearch/Model/` is still handed the home directory rather than reading it

## Build and size checks

A clean build is part of the bar; nothing builds the app for you, so this is on you.

```sh
xcodegen generate                 # only after editing project.yml
xcodebuild build -project Ollie.xcodeproj -scheme Ollie -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Ollie.xcodeproj -scheme Ollie -configuration Release \
  CODE_SIGNING_ALLOWED=NO
find ~/Library/Developer/Xcode/DerivedData -name "Ollie*.app" -maxdepth 6 -print -quit
```

- Zero **new** warnings. Pre-existing ones are not your problem; new ones are.
- No `@unchecked Sendable`, `nonisolated(unsafe)` or `assumeIsolated` added without a stated reason.
- The type-checker did not time out. The fix for a timeout is an annotation, not a restructure.
- Release binary growth under **2%** for an ordinary change.

### Lint

```sh
./scripts/lint.sh
```

SwiftLint owns the rules that catch defects, including the two checkable comment rules — the
100-character cap and the ban on stacked comment lines. Errors block; warnings do not. There is no
formatter, deliberately — the configuration and the measurements behind that are in
[development.md](development.md#formatting).

The script then runs `scripts/check-settings-search.js`, one check SwiftLint can't: every
`SettingsAnchor` must be claimed by a section, and every row in `SettingsSearchCatalog` must be
marked by a `SettingsRowTitle`. Either gap compiles and reads fine, and fails only at runtime as a
search result that navigates and then sits there.

## Performance measurement

With General > Diagnostics enabled, `Platform/Signposts.swift` emits eight intervals on the `nl.bentjes.ollie.perf` subsystem: `AppCore.start`,
`AppIndex.scan`, `AppIndex.rank`, `PaletteWindowController.show`, `UninstallScanner.discover` and
`UninstallScanner.measure`, `FileSearchService.search`, and `Notes.search`. Open the Time Profiler or
`os_signpost` instrument in Instruments and filter to that subsystem; nothing needs recompiling.

None of the benchmarks below join the suite, so each is registered in `run-tests.sh` as `run index`
instead: `--index` hands it editor flags without queueing it, and without that entry nothing in the
file resolves. Keep the entry's source list matching the command beside it.

Run the real Spotlight-backed file-search benchmark separately from the deterministic harnesses:

```sh
swiftc -O -swift-version 6 Ollie/Platform/Diagnostics.swift Ollie/Platform/Signposts.swift \
    Ollie/Features/Launcher/Model/SearchRelevance.swift \
    Ollie/Features/FileSearch/Model/*.swift \
    Ollie/Features/FileSearch/Service/FileSearchService.swift \
    Tests/file-search-performance.swift -o /tmp/file-search-performance
/tmp/file-search-performance
```

Every query runs twice: once on the shipped rules and once with five extra user patterns, so the output
says what the ignore list itself costs rather than only what Spotlight does.

The calculator benchmark is deterministic — an injected clock, calendar and rate table — so it is a
timing harness rather than an assertion one, and stays out of `run-tests.sh` for that reason:

```sh
swiftc -O -swift-version 6 Ollie/Features/Calculator/Model/*.swift \
    Tests/calc-performance.swift -o /tmp/calc-performance
/tmp/calc-performance          # µs per query, by grammar
/tmp/calc-performance --probe  # every answer as JSON, to diff two builds
/tmp/calc-performance --cold "10kg to lb"   # first query, including catalog decode
```

`Tests/text-diff-performance.swift` is the same shape for `TextDiffEngine`: build it with `-O`
against the engine, pass a token count, a workload (`dense`, `sparse`, `equal`, `empty`) and an
iteration count for timings, or `--probe` to diff every chunk between two builds.

`Tests/emoji-search-performance.swift` times uncached queries, typing prefixes and memo hits against
the loaded catalog, with process RSS and footprint as JSON; `--names` also lists every catalog name
missing from its own top five results, and `--languages fr,ja` loads those keyword packs first (run it
from the repo root):

```sh
swiftc -O -swift-version 6 Ollie/Features/Emoji/Model/{EmojiCatalog,EmojiData.generated}.swift \
    Ollie/Features/Emoji/Service/{EmojiIndex,FrequentEmojiStore}.swift \
    Ollie/Features/Launcher/Model/SearchRelevance.swift Ollie/Platform/{AppPaths,Memo}.swift \
    Tests/emoji-search-performance.swift -o /tmp/emoji-search-performance
/tmp/emoji-search-performance --names
/tmp/emoji-search-performance --languages fr,ja
```

`Tests/notes-editor-performance.swift` installs a 100,000-character note in a real rendered editor and
prints, as JSON, the median over 30 runs of the install with its full restyle, one typed character at
the end, middle and start, and a caret move between distant lines. The budget is 150 ms, 8 ms (end and
middle) and 4 ms:

```sh
N=Ollie/Features/Notes
swiftc -O -swift-version 6 Ollie/Platform/{Diagnostics,Signposts,Appearance,NotificationToken}.swift \
    Ollie/DesignSystem/{Theme,InterfaceMetrics}.swift \
    Ollie/Features/TextInjection/Service/InjectableTextView.swift \
    $N/Model/{NoteDocument,NoteMarkdown,NoteMarkdownParser,NoteInlineScanner}.swift \
    $N/Model/{NoteEditPlan,NoteEditAction,NoteFormatting,NoteMarkdownEditing,NoteRevealPolicy}.swift \
    $N/UI/{NoteMarkdownTypography,NoteBlockDecoration,NoteMarkdownStyler,NoteMarkdownRenderer}.swift \
    $N/UI/{NoteCheckboxGeometry,NoteBlockLayoutFragment,NoteLayoutFragmentProvider}.swift \
    $N/UI/{NoteTextViewEditing,NoteTextView,NoteEditorView}.swift \
    Tests/notes-editor-performance.swift -o /tmp/notes-editor-performance
/tmp/notes-editor-performance
```

`Signposts.interval` owns an explicit `defer` around the wrapped work on purpose. The obvious spelling
leaks the interval when the work throws, because the `.end` emit is skipped on the throw path and the
instrument then shows an interval that never closes.

### Recorded baselines

Measured at the end of the 2026 refactor, on `main`. Useful as orders of magnitude, not as contracts.

| | Value |
| --- | --- |
| Release binary | 3,655,736 B (from 3,471,592 B at the start of the refactor) |
| Resident memory | 40–80 MB in normal use; the hard ceiling is 100 MB |
| `SettingsPaneScanner` warm scan | 0.014 ms (16.5 ms cold), 52 panes |
| Largest view / owner | `RootPaletteView` 662 lines, `AppCore` 284 lines |
| Comment density | 1,653 of 27,289 source lines (6.1%) |
| The harness suite | ~15 s wall clock, 11-way parallel (~98 s serial, ~140 s before either) |
| `palette-selection-test` | 111,684 assertions — a tripwire: a change in this count means the row-order model moved |
| Rendered Notes editor, 100,000 characters | 30 ms install and full restyle; 7.5, 5.9 and 3.3 ms per character typed at the end, middle and start (5.2, 3.1 and 0.6 ms with rendering off); 0.6 ms per caret move |
| `count items of trash` | 5,000 ms against a cold Finder on an *empty* Trash, 110 ms warm — why AppleScript is detached |

Launch time, allocation counts and RSS have never been captured as numbers. The signposts are in place,
so any of them can be taken from `main` whenever a change makes it worth knowing.

## Manual regression sweep

There is no UI test suite, so this is it. Run the core sweep for any change that touches the palette;
run the scoped section for whatever feature you touched. Budget about five minutes plus three per
section.

Run against the **Debug channel** (`Ollie Dev.app`, `nl.bentjes.fredie.dev`). It has its own prefs,
caches, TCC grants and login item, so this cannot disturb an installed copy.

### Core

- Palette hotkey opens the launcher; pressing it again closes it; Escape clears a non-empty query,
  then hides on a second press; clicking away closes it
- Search a mode command (Search Emoji, Search Quicklinks, Search Files, Quick AI)
  and run it: Escape returns to the launcher **with the query still typed and the row still
  selected**, and the next press clears it. The same screen from its own global hotkey hides the
  palette instead, and shows its own header icon rather than a back chevron
- ⌘⎋ from any depth lands on an empty root search with the window still open — **must be checked on
  a real keyboard**: macOS claims the chord, so `CommandEscapeTap` is the only thing that delivers it
  and it needs Accessibility granted to the running build. With the palette closed, ⌘⎋ still does
  whatever macOS does with it
- A bare ⌫ in an empty field walks the same path Escape does
- General ▸ Escape Key Behavior set to `Close window and pop to root`: Escape on any screen closes
  the window, and reopening lands on the root search whatever Pop to Root Search says
- Reopening focuses the search field with an empty query, in the same position and at the same size
- Compact mode: typing expands it, and the search bar does **not** shift vertically during the swap
- With a CJK IME: the placeholder clears as soon as composition starts and the composing text never
  overlaps it; cancelling composition brings the placeholder back, and the list filters only once the
  candidate is committed — check on a second summon too, where first responder never moved
- Typing filters instantly; ↑/↓ move the highlight and scroll it into view without yanking the list
- ⌃N/⌃P move the highlight as ↓/↑ do; ⌃F/⌃B step the emoji grid's selection, and the caret elsewhere
- The highlight always sits on the row the footer pill describes
- With a calculation typed, the calculator card is first and is selected first
- ⌘↵ on a number, unit or money card puts the answer in the search bar with the caret after it, so
  ` * 2` typed straight away extends it — from ⌘K too; a date or time card offers neither
- With macOS set to a decimal-comma region (Italian), `2,3 + 1,5` answers `3,8`, `max(2,5; 3)`
  answers `3`, and ↵ pastes `3,8`; General ▸ Calculator ▸ Number format `English` restores `2.3 + 1.5`
  and re-renders past Calculator History in the chosen format
- Section headers appear in order: Favorites, Applications, System Settings, Quicklinks,
  System Actions, Window Management, Custom Commands, Commands
- With a non-ASCII input source active, ⌘K opens Actions; ↑/↓ move it, ↵ activates, Escape closes it
- In either ⌘K Actions panel, typing filters immediately in the bottom search band without changing
  the palette query; sections survive filtering, **No Results** is centred, and no dissolve covers the
  last row. The native caret blinks; mouse drag and ⌘A select text; ←/→ move through it; ↑/↓ still
  move the menu highlight. Escape clears a non-empty query, then closes the menu on the next press
- The bottom-left app menu also searches from its bottom band; every header menu — including Emoji
  categories, File Search filters and extension dropdowns — searches from its top band
- A long menu opens with unchanged row insets; while scrolling, rows can reach the panel edges
- A click in the palette but outside its menu closes only the menu; a click outside the palette
  closes both, regardless of the menu query; the next summon accepts typing immediately
- Footer menus are about 30pt wider; their row hover keeps the shared 10pt menu-row corner
- Tab toggles launcher ↔ AI; bare Backspace on an empty query backs out of a sub-screen
- Launching an app focuses it; escaping the palette returns focus to the app you came from
- No flash, flicker or reflow on open, and row metrics unchanged

### Launcher and icons

- Every installed app appears; Settings panes appear under System Settings; running apps show the dot
- Icons render with no placeholder flash on reopen, and Settings ▸ Applications scrolls without hitching,
  even with the scrollbar thumb dragged from end to end in under a second
- An app removed since the last open drops out after a reopen
- Learned ranking still surfaces your habitual result for a short query
- An application row drags onto the Dock and into a Finder window as a copy, never a move, and a
  landed drop hides the palette; a click still launches; no other kind of row drags

### Hotkeys

- The palette, emoji, File Search, and all three Notes shortcuts fire; a per-app shortcut
  toggles that app
- Recording captures a shortcut, and the old binding does not fire while recording
- A conflicting binding is rejected and names its current owner
- A double-tap binding fires; externally remapped modifier chords record and fire literally
- Every binding survives quit and relaunch
- `Enable Commands` off leaves every pane-owned command listed, searchable and firing — Notes,
  Emoji, File Search, Quicklinks, Calendar, AI and the two layout commands

### Uninstall

- The launcher's Uninstall action opens the scan screen; the bundle is first, leftovers sorted by path
- Rows appear with no loading copy at any point; folder sizes fill in behind them and totals climb
- Locked rows cannot be checked; filtering by name works
- Confirming moves items to the Trash and they are **recoverable from it**
- Escaping mid-scan cancels promptly with no spinner left behind
- Hiding and immediately restoring the screen never strands an in-flight file icon as a placeholder

### Quicklinks

- A quicklink opens its destination; `{argument}` prompts in order and Backspace steps back
- `{selection}` falls back per the Settings choice
- Pin, duplicate, delete and Open with Default all behave; import and export round-trip
- Display order is pinned first by pin time, then by name

### Apple Shortcuts

- Off out of the box: the pane lists nothing and no shortcut reaches the launcher
- Switching on lists every shortcut with the Shortcuts app's icon; ↵ on a row runs it
- A shortcut added in Shortcuts appears on the next launcher open
- A row's hotkey runs it with the palette closed; switching the feature off silences it
- Unchecking a row hides it from search, and its hotkey still fires
- Deleting a shortcut in Shortcuts frees its alias and hotkey on the next launcher open
- A shortcut that fails shows Ollie's dialog with the tool's error

### File Search

- With File Search **off**: Search Files is absent, its shortcut no-ops, and no permission appears
- Enabling in Settings exposes Search Files immediately; it persists across relaunch and backup import
- Disabling during a query cancels it and returns the open screen to the launcher
- File Search and Quicklinks remain independently visible in all four enabled/disabled combinations
- An empty query performs no search; a filename query returns only files and folders beneath the scopes
- Library internals, generated trees, application bundles and hidden paths do not appear
- Visible custom top-level home folders and cloud-drive files remain searchable
- Return opens, Command-Return reveals in Finder, and Copy Path keeps the palette open with a HUD
- A file and a folder drag into Finder as copies and into a browser's upload field; a cancelled drag
  flies back and leaves the palette up, a landed one hides it
- Replacing a query quickly never lets an older result list overwrite the current query
- A broad `.` search can be scrolled end to end; leaving it releases its fitted icons, and repeating the
  cycle does not raise the post-close memory floor
- Removing home and adding one folder narrows results to it; restoring the default brings them back
- A cleared scope list returns nothing rather than falling back to home, and never hangs
- A missing scope shows the warning triangle without failing the rest of the search
- Adding `*.log` takes effect on the next query with no relaunch; removing it restores those results
- Built-in ignore rows carry no remove button; user rows do, and a duplicate or blank is refused
- Recording a shortcut opens the palette straight into File Search, hidden from the launcher or not
- Search Files is absent from Settings ▸ Commands, and `Enable Commands` off leaves its shortcut live
- Export, clear both lists and the shortcut, re-import: all three return, defaults undo not duplicated

### Notes

- With Notes **off**: all three commands are absent, their shortcuts no-op, and the Notes directory is
  not created
- Enabling in Settings projects Show Notes, Create Note, and Search Notes immediately; the pane's
  visibility checkboxes and recorders are the only ones — Settings > Commands lists none of the three
- Show Notes opens the last active note and focuses an already visible window without hiding it
- Create Note makes one unique Untitled file, including as the first action in an empty channel
- Command-P and the Browse button focus search, arrows move selection, Return opens, and Command-N
  creates
- Empty switcher search reads the complete recent list; title and body searches rank correctly and a
  superseded query never publishes
- An Untitled note titles itself from its first line as it is typed, in the title bar and — after the
  autosave — in the browse list; naming it replaces that, and clearing the name brings it back
- Inline rename updates the Markdown filename without changing source, and starts from that filename
  even where the row shows a derived title; collisions receive a suffix
- Delete confirms through Ollie, moves the file to Trash, and selecting another note never loses an
  unsaved edit
- An existing `Floating Note.md` appears as an ordinary note without conversion
- A note using every construct renders in Dark and Light: sized headings, emphasis, strikethrough,
  inline code, coloured links, bullets, numbers, checkboxes with space between tasks, lists nested at
  two and four spaces, quote bars, a code band with its language label, and a rule
- The caret's line shows raw Markdown in the tertiary colour and re-renders when the caret leaves; a
  multi-line selection reveals every selected line, and Select All shows the whole source
- Dragging a selection across rendered lines does not jump under the pointer; the lines reveal on
  mouse-up
- Clicking another app renders the whole note; clicking back reveals the caret line again
- Inside a code block both fences show and Markdown inside it stays literal
- A table shows as its literal source in the code font, with no styling inside it; adding the `| --- |`
  row under existing rows turns them all into the table at once
- Bullets, numbers and checkboxes are a neutral gray, bullet, numbered and task items are evenly spaced,
  and revealing a bullet or numbered line leaves its text where it was
- A checkbox click toggles without moving the caret, autosaves, and Command-Z restores it; the file on
  disk shows `[x]`
- A link click opens the browser, a click at the label's edge places the caret, a `file:` link does
  nothing, and a link on the caret's line is editable text
- Return continues and leaves lists and quotes, Tab and Shift-Tab nest, ordered lists renumber, `[] `
  becomes a task, and every formatting shortcut works and undoes in one step
- Pasting a URL over selected text makes a link; pasting anything else is plain text
- Copy from a rendered line pastes raw Markdown into another app; Quick Actions replace selections in a
  rendered note and are styled at once
- The derived title of an Untitled note shows no Markdown markers
- A narrow window wraps list items under their text, not under the marker
- Typing new lines, wrapping text, and pasting grow the note vertically without changing its width,
  and deleting shrinks it back to the 180pt floor; the top edge stays put until growth reaches the
  screen's bottom, then the window moves up. It stops at 860pt or the screen's usable height and
  scrolls. A dragged height holds until the next keystroke, which fits the window again. Switching
  to a shorter note shrinks it. Repeat with rendering on and off, Find and the formatting bar open,
  and on a secondary display
- With Render Markdown **off**, the note is fully literal (markers visible, links inert, task syntax
  plain) and Return, Tab, Delete, and formatting-looking shortcuts keep native plain-text behavior;
  flipping it back re-renders without dirtying the note or touching undo
- Edit one note, switch to a shorter note, then Undo and Redo: the new note remains intact and the app
  does not terminate
- With rendering on and off, ⌘Z undoes and ⇧⌘Z redoes typing, deletion and paste while another app's
  menu bar is visible; both update the footer and autosave the restored source. Editing after undo
  discards redo; reopening a note after switching away starts with no history
- Marked-text input, emoji, combining marks, Copy, Cut, Paste, Select All, Undo, and Redo preserve
  exact source; ⌘F finds occurrences in the active note with rendering on and off, and Escape closes
  the find bar before hiding Notes
- An empty note shows `Start writing…`; ⌘F moves it below the find bar without overlap, and closing Find
  restores its position. The footer count is right after typing, pasting and undoing
- With Render Markdown and Show Formatting Bar on, the band under a note holds the character count on
  the left and the round formatting button on the right; with either setting off, the old centred
  count footer is back and nothing else moved
- The bar starts collapsed, ⌥⌘T and the round button both expand and collapse it, the buttons slide out
  from behind that button, and the state survives switching notes, hiding the window and a relaunch
- Every bar button applies its formatting, undoes in one step with ⌘Z, and autosaves; clicking keeps the
  caret where it was and the caret's line stays revealed
- Buttons light for the selection: inside bold, on a list, quote, heading or code line; clicking a lit
  button removes that formatting and the button goes dark
- Hovering a button shows its name and shortcut above it, fully visible and not clipped by the capsule;
  the heading button's tooltip does not show while its menu is open
- The heading menu opens above the capsule, aligned to its left edge, shows the current level checked,
  and applies a level on click; it closes on Escape, on a click anywhere in the note window (including
  the heading button itself, which must not reopen it), on typing, on ⌘P, and when another app is clicked
- At the smallest window size all eleven controls show and the count is hidden, the note's text keeps
  its inset in both states, the heading menu still opens in full above the capsule, and widening the
  window brings the count back
- ⌥⌘C and ⇧⌘B toggle a code block and a quote; with Render Markdown off they do nothing special
- Settings > Notes > Show Formatting Bar is disabled while Render Markdown is off, Settings search for
  "formatting" lands on it, and a backup round trip restores it
- With VoiceOver, the bar reads as "Formatting" with each button named, lit ones as selected, the round
  button announcing Expanded or Collapsed, and the heading button its level; menu rows read their titles
  and the current one as selected
- Traffic lights sit top-left, the title is centred **on the window**, and the capsule is top-right, all
  on one line; the yellow light is disabled and green zooms
- Each capsule button shows a hover capsule and a native tooltip, and fires its action
- Dragging the title bar moves the window and dragging an edge resizes it; both survive relaunch
- Clicking another app leaves the panel visible; Escape, Command-W, and the red light hide it
- Command-Q does nothing anywhere; with Settings in front, Command-W closes Settings
- Hiding restores the previous external app or Ollie window
- Open Notes Folder opens Finder with the active Markdown file selected, or the folder with no note
- Hide a saved checklist, reset its boxes in another editor, and reopen: the boxes match the file
- Reopen an unchanged note: Undo still works; an external content change starts fresh history
- Remove the active file while hidden: reopening selects a remaining note or shows the empty state
- Deleting every note closes the browse list and leaves one clean empty state with no character count;
  Command-N from there creates and selects one note
- The browse list fades only at its bottom edge and rests opaque once it reaches the end
- Quitting inside the debounce window saves the last edit
- Over a light desktop, the corner matches the palette's, the shadow follows it, and no dark edge shows
  around the glass controls

### Calculator and currency

- `2+2` shows a card; ↵ copies and records to history; unit and date conversions work
- In Calculator History, ⌃X deletes a row and ⌃⇧X clears the history behind a confirmation
- A currency query answers from the cached snapshot; with the cache cleared and no network it reports
  rates unavailable rather than guessing
- A bare amount (`1 usd`) answers in the Mac's region currency, and follows a change to
  System Settings ▸ General ▸ Language & Region without a relaunch — and nothing prompts for location
- A crypto query (`1 btc`, `0.5 sol to eur`) answers, and `1 usd to btc` stays in plain notation

### Calendar and meetings

- With Calendar **off**: no launcher entries, no card, no permission prompt at launch
- Enabling shows the consent dialog **before** the macOS prompt; declining prompts for nothing
- After Calendar permission is reset, Settings ▸ Calendar offers `Allow Calendar Access…` and asks
  again; after denial it offers System Settings instead
- With a meeting four minutes out, an empty palette shows the card on top, provider glyph and all
- The countdown steps on the minute boundary rather than on a keystroke
- ↵ joins: a Zoom link opens the Zoom app, and the browser where no app claims the scheme
- Typing a character swaps the card for the calculator's; ↑/↓ never lands on a phantom row
- Unchecking a calendar drops its events from the launcher and My Schedule, and survives a relaunch
- `Show in launcher` off drops the meeting entries from the launcher, yet typing `My Schedule`
  still finds the command, and it still lists the meetings
- Adding or deleting an event in Calendar.app updates an open palette without a reopen
- A meeting with no link is listed and searchable, and answers Open in Calendar rather than Join
- Two upcoming meetings with titles in reverse alphabetical order appear earliest first in the
  launcher's Meetings section and the `Meetings` category listing, even after opening the later one
- Import a backup taken with Calendar on: it comes back **off**, and no calendar toggle travels
- Calendar in Menu Bar on Disabled: the calendar item is gone and Ollie's own item is unaffected;
  turning `Show in menu bar` off leaves an enabled calendar item in place, and both off leaves neither
- On Meeting Title with Show Upcoming Events at 5 minutes, the title and countdown appear at T-5 and
  step on the minute boundary, not on a keystroke
- `Only show events with meetings` hides a linkless event and shows it again when unchecked
- `Hide when there are no upcoming events` removes the item whenever it would show only the glyph or
  `No upcoming events`: on Today after the last event, on 5 minutes between meetings too. It returns
  with the next event and never moves the `Calendar in Menu Bar` picker off its choice
- Hide Current Event on Automatically clears the entry at the start and hands the space to the next
  event inside its lead time; on 5 minutes it lingers counting up, then clears
- Clicking the calendar item opens `Join <title>`, `Open in Calendar...`, `My Schedule` and
  `Calendar Settings...` and nothing else; the second opens that event in Calendar.app, while a bare
  click never joins
- Camera Preview on: ↵ on the join card opens the panel **already showing live video** — no black
  frame, no blank mid-preview; ↵ joins, Esc drops the join; the camera light goes out with the
  panel, and the first run prompts once, before any panel appears
- With Open Camera or the join card up, changing a video effect in Control Center leaves the preview
  live; the next click outside both the panel and system UI then closes it, and Esc does once the
  panel is clicked
- A meeting that ends leaves the launcher results and `My Schedule` on the same minute boundary it
  leaves the menu bar, with the palette open or closed over the end
- Auto Join on: the meeting opens itself at its start, **once** — dismiss it and it does not return.
  With confirm on and camera preview off, the dialog asks first
- Arming Auto Join during a meeting already under way joins nothing
- `Only join known meeting services` on: an event whose only link is a booking page or document
  neither asks nor opens at its start, while a Zoom or Meet event beside it still joins; the join
  card still offers both
- Sleeping over a meeting's start and waking past it reloads the events; one still inside the window
  joins, one long past does not
- Create Event writes to the default calendar and shows up on the card, the schedule and the launcher
  without a relaunch; a blank title leaves the dialog up on ↵ and on a click
- Arrow keys move the caret in the New Event title field, and still step the Set Volume slider
- Every command row of Settings ▸ Calendar has Add Alias, Record Hotkey and a checkbox, and none of
  the five appears in Settings ▸ Commands
- Export with auto join and camera preview on, import onto a clean profile: both come back **off**,
  while the menu-bar settings carry over

### System actions and window management

- A confirmation-gated action (Restart, Quit All) confirms, showing the subject's own glyph
- Empty Trash confirms while Finder's "Show warning before emptying the Trash" is on, and runs
  without a dialog once it is off
- Volume actions show the volume HUD; everything else shows the message pill
- Toggle Microphone Mute works from the launcher and a global hotkey with the palette closed;
  its pill reports Microphone Muted / Microphone Unmuted, input audio follows that state, and input
  gain and output audio stay unchanged. Switch the default input and repeat; an unavailable or
  externally controlled mute reports failure. Rapid repeats while a change is pending are ignored
- Holding a bound hotkey does **not** stack dialogs
- Lock Screen locks from a global hotkey with the palette closed, including a combined ⌃⌥⇧⌘ binding
- Window commands move the window you were last in; cycle-on-repeat steps ½ → ⅓ → ⅔
- "Top Half" lands flush with the top of the visible frame, on a secondary display too
- A command with the Notes window focused places Notes, not the app behind it
- Cycling, Restore, custom sizes and display moves all work on Notes and on Settings
- Fullscreen on Settings toggles it; on the Notes window it does nothing
- With the note switcher open a command places Notes; the switcher and HUDs are never placed
- Rooms: create one from Switch Room; ⇥ glides the preview through its layouts; ↵ lands its windows
  with the gap, hides other apps and parks their extra windows; quitting, `kill -9` then relaunching, and
  turning Window Management off each bring every window back.
  Repeat on two displays and with Reduce Motion on

### Extensions

- Open a view-command deeplink with `fallbackText=beta`, with the palette hidden and already open:
  the field shows `beta`; a locally filtered List/Grid shows matching rows, and a command using
  `onSearchTextChange` receives the query when it mounts. Repeat without fallback text: the field
  starts empty. A no-view command receives the prop without prefilling the search field.
- Every command under Settings ▸ Extensions has Add Alias, and Record Hotkey when the mode is
  supported; an alias set there finds the command from its start and shows the chip
- Hiding the extension from the launcher, or turning off Show in launcher, dims its alias fields

### Settings and backup

- General → Automatically check for updates defaults on; turn it off and relaunch: it stays off,
  no background check or update prompt occurs, and Check for Updates still works. Re-enable it:
  checks resume. Settings search for "updates" reveals the toggle; settings.json edits and a backup
  round trip preserve the choice.
- Every pane renders and the sidebar switches without flicker
- Disabling Launcher from Features keeps Settings in front and removes Applications and Emoji;
  enabling it restores those panes. Leave the switch in its original state after testing.
- A feature switch takes effect in the launcher immediately; every setting survives relaunch
- Export produces a `.ollie`; import applies it and reports a per-category summary
- Untick a category on export, and the import picker greys that row out rather than offering it
- Untick a category on **import** and confirm it did not arrive, while the ticked ones did
- A file whose `manifest.json` `format` was hand-edited is refused **with a message naming it**
- Cancelling the save panel leaves nothing in `~/Library/Caches/nl.bentjes.fredie.dev/backup-staging/`
- Nothing in the extracted tree names a Keychain item, an extension, or an AI conversation

### Clean install

The realistic storage failure is a store that crashes on an absent file rather than starting empty.
Wipe the Dev channel and check that path directly:

```sh
rm -rf ~/Library/Caches/nl.bentjes.fredie.dev
rm -rf "$HOME/Library/Application Support/nl.bentjes.fredie.dev"
rm -rf ~/.config/fredie-dev
defaults delete nl.bentjes.fredie.dev 2>/dev/null || true
tccutil reset Accessibility nl.bentjes.fredie.dev 2>/dev/null || true
```

- Launches with every store directory absent — no crash, no hang; onboarding runs
- Onboarding has two pages; Back and Continue preserve recorded shortcuts. Spotlight and Fn/Globe
  open their Keyboard settings destinations, and returning retries launcher shortcut registration.
  Permissions update after grants; skipping them still finishes. General › Setup reopens the flow.
  The isolated Debug flag `--preview-ollie-onboarding` opens the actual onboarding window without
  starting background features and requires bundle id `nl.bentjes.ollie.verification`. Add `--dark`
  to inspect Dark appearance; the preview otherwise uses Light.
- Palette opens and lists apps; quicklinks and calculator history are all empty
  and all accept a first entry
- Notes creates no directory until Show, Create, or Search is first used, then accepts its first edit
- **Every setting shows its intended default.** Walk the panes: this is what catches a broken
  absence-versus-`false` read
- Quit and relaunch: everything created above persisted
- Nothing was written outside `nl.bentjes.fredie.dev/`. Channel isolation is not negotiable — a Dev build
  writing into the stable app's directory is a defect even though the data is disposable

## Ollie integration

Inline snippets delete the forwarded trigger and send one paste shortcut. The shared text injector
temporarily borrows the clipboard for 400 ms, restores all original clipboard formats if it still owns
the clipboard, and leaves a newer copy untouched. The original clipboard is read when `>` opens the
session and reused only while its change count is unchanged, so the completing key never waits on a
slow clipboard owner; the insertion sound starts after the event tap returns. Temporary snippet content is marked transient so it
does not enter clipboard history. Following key events wait until the clipboard is restored; changing
applications cancels pending replay, and a mouse click flushes buffered input before the click.
Verify repeated fast `>mar` expansions in Helium, including typing immediately afterward, and check
that the full email and the original clipboard survive. Harnesses use a private pasteboard and a
native text editor; they do not prove browser delivery.

The `ollie-*-test` harnesses exercise imported services, clipboard storage, serialized AX work,
recording cancellation and reconnect, and verified paste restoration with synthetic files and fake
providers. Settings history tests cover feature visibility, filtered search and disabled-pane routing. No live transcription API key is needed.

A Debug-only offscreen view harness requires the dedicated bundle identity
`nl.bentjes.ollie.verification` and the `--verify-ollie-ui` argument. It mounts every available native
settings pane and captures the compact menu in both appearances to `/tmp/ollie-native-verify`.
Native Form controls are composited separately and do not appear reliably in offscreen PNGs; those
images prove mounting, not settings visual quality. Build it with
`PRODUCT_BUNDLE_IDENTIFIER=nl.bentjes.ollie.verification PRODUCT_NAME='Ollie Verification'`.
It does not start capture services or use the installed app’s data. These layout renders do not
replace testing permission prompts, real microphone capture, or actual cross-app input.

The same isolated verification identity supports `--preview-ollie-settings` for native visual and
interaction checks. It enables every feature pane in that identity's preferences and opens Settings
without calling `AppCore.start()`, so capture services do not start. Use it to inspect grouped forms,
recorders and editor dismissal without changing the installed app's preferences. Release builds
contain neither verification entry point.

## Feature lifecycles

`feature-availability-test` runs the shipped ownership policy and action mappings with Release
optimization, which reproduced a startup crash in a bound `Set.contains` call. It covers
all eleven roots independently, all-off with saved child flags, global commands, palette modes,
shared Clipboard/Snippets and Spaces navigation. `palette-navigation-test` rejects disabled roots and
ancestors. `media-import-state-test` uses private defaults, a temporary ledger and an injected delayed
scan to prove disabled actions and stale results cannot restart work. `custom-command-test` verifies
cancellation before launch and during a headless shell run. None of these opens feature windows.

## App-wide diagnostics

General > Diagnostics is the sole optional logging switch (`general.diagnostics` in settings.json).
It applies immediately to window switching, clipboard and snippet traces, informational Dictation
logs, extension console output, notification debug events and performance signposts. Warnings and
errors remain available when off. Dictation's Logs tab remains a viewer; it has no separate switch.
`diagnostics-test` verifies the shared live gate, lazy message evaluation, essential errors and that
signpost gating never skips application work. The Dictation harness covers log filtering.
