# Development

The local loop: set up, build, run, regenerate. Shipping a build is [release.md](release.md);
verifying a change is [testing.md](testing.md).

## Requirements

- macOS 26 or later (Liquid Glass).
- Xcode 26 — it provides the SwiftUI macro plugin and the SDK.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), and for linting:
  `brew install swiftlint`.
- Node, for the generators and for the two stub servers `run-tests.sh` drives. It is the only
  scripting runtime here — building the app still needs none of it.

## First-time setup

Use the existing Apple Development identity configured in `release/Release.plist`; see
[signing.md](signing.md). For the usual build, install, and launch flow, run
`./scripts/release-local.sh`.

## Build & run

```sh
open Ollie.xcodeproj    # then ⌘R
```

Or from the command line:

```sh
xcodebuild -project Ollie.xcodeproj -scheme Ollie -configuration Debug build
```

`xcodebuild` uses whatever `xcode-select` points at; if that's the Command Line Tools rather than
Xcode, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the SwiftUI
`@State`/`@FocusState` macros need Xcode's macOS platform).

`Ollie.xcodeproj` is committed and generated from `project.yml` via XcodeGen — after changing
project settings in `project.yml`, run `xcodegen generate` and commit the result. There is no
`Package.swift`, and `Bundle.module` must never be used.

### The dev channel

Debug builds are a separate channel: **`Ollie Dev.app`**, bundle id `nl.bentjes.fredie.dev`. Every
persisted thing is keyed by bundle id — `~/Library/Preferences/<id>.plist` (settings and hotkey
bindings), `~/Library/Application Support/<id>/` (the onboarding marker, Notes, quicklinks,
calculator history, launch ranking and frequent emoji; Notes unless
a folder is chosen),
`~/Library/Caches/<id>/` (exchange rates, the update check, staged downloads), the opt-in
`~/.config/fredie-dev/settings.json` (`fredie` on stable), the `SMAppService`
login item, and the Accessibility / Input Monitoring (TCC) grants — so a local build can neither read
nor clobber an installed app's state, and both run side by side.

**What earns a place in Caches is refetchable, and nothing else.** Anything the user would notice the
loss of goes in Application Support: `~/Library/Caches` is excluded from Time Machine and the system
reclaims it under disk pressure without saying so.

Consequences worth knowing:

- The dev build asks for Accessibility on its own the first time, and starts with **no** hotkeys bound
  and onboarding unseen. Grant and bind once; it persists across rebuilds, because the fixed build path
  and the Apple Development identity keep the TCC grant alive.
- Don't bind the same global hotkey in both — whichever registered first wins.

## First-launch onboarding

The first launch shows two compact pages: shortcuts, then permissions. The launcher recorder keeps
existing bindings; **Use ⌘Space** explicitly assigns the suggested shortcut after checking Ollie's
other bindings. Spotlight opens its Keyboard Shortcuts settings, where the user disables
Show Spotlight search and clicks Done. Returning to Ollie retries shortcut registration. Fn/Globe opens
Keyboard settings with guidance to choose Do Nothing only when using Fn for Ollie dictation.
These links never change macOS preferences automatically; users restore
those settings themselves if they later disable Ollie's features.

Accessibility and Microphone grants are optional and refresh while the window is open. **Set Up…**
under Dictation enables that feature and opens its settings for the shortcut and provider credentials.
Raycast import remains in Backup settings. **General › Setup › Open Setup…** reopens onboarding
without resetting preferences. The existing per-bundle first-run marker still prevents repeated
automatic presentation, including after closing the window mid-flow.

## Editor

Xcode works out of the box and needs nothing here. Everything below is optional, and which editor you
use is your business — the repo prescribes none of it.

VS Code gets code intelligence from SourceKit-LSP, which needs a `buildServer.json` because there is no
`Package.swift`. Build once, then hand the log to the sync script — that writes both `buildServer.json`
and the flag database:

```sh
brew install xcode-build-server
xcodebuild -project Ollie.xcodeproj -scheme Ollie -configuration Debug \
    -derivedDataPath build/DerivedData build 2>&1 | tee /tmp/ollie-build.log
./scripts/sync-lsp.sh /tmp/ollie-build.log
```

Both files are git-ignored because they embed absolute paths, and `sourcekit-lsp` looks for
`buildServer.json` at the workspace root by name, so it cannot live in a subfolder. After this the
**Build Ollie.app (debug)** task (⌘⇧B) and **F5** re-run the script on every build, so new and
renamed files keep resolving.

**Do not run `xcode-build-server config`.** It writes `kind: xcode`, and in that mode the server ignores
`.compile` entirely — it serves flags from a cache it scrapes out of `.xcactivitylog` instead. That
cache is only refreshed when `LogStoreManifest.plist` advances, and when the manifest stops updating
(it does) the editor silently pins itself to the source list from some older build: every reference to a
file added since reads *cannot find type X in scope*, in every file, until you restart the server. It
also mixes Release entries in with Debug and lets them win. `scripts/sync-lsp.sh` keeps the mode
`manual`, where `.compile` is the single source of truth.

### Symbols in `Tests/`

`xcodebuild` never compiles the harnesses — they are not in the Xcode project — so nothing emits a
compile command for them, and without one an open harness reports every shipped type it uses as *cannot
find in scope*. Measured on `fuzz-test.swift`: 60 errors with no entry, 0 with one.

```sh
./scripts/run-tests.sh --index    # merge the harness compile commands into .compile
```

It reads the source lists from `run-tests.sh` itself, so they cannot drift from what the suite actually
compiles. `scripts/sync-lsp.sh` runs it too. Three things it has to get right, all of which fail
silently otherwise: every path is absolute, because `sourcekit-lsp` resolves the command itself and does
not apply `directory` to relative arguments; the command carries an explicit `-sdk`; and each entry
claims **only files under `Tests/`** — its harness plus any helper compiled beside it. The command
still lists every shipped source it compiles, so symbols resolve inside the harness, but claiming a
shipped source too would hand it this three-file command instead of the app's, and `.compile` is
last-wins.

A benchmark that stays out of the suite still needs flags, so `run-tests.sh` registers it as
`run index <name> <source...>`: `--index` emits its compile command and the runner never queues it.

Re-run it after adding a harness, then **Swift: Restart LSP Server** from the Command Palette — an
already-running server does not re-read `.compile`.

## Linting

```sh
./scripts/lint.sh          # lint the whole project
./scripts/lint.sh --fix    # auto-correct the mechanical subset first
```

[SwiftLint](https://github.com/realm/SwiftLint) is the only code-quality tool here. `.swiftlint.yml` at
the repo root excludes the generated files and the two off-limits files in `DesignSystem/Scrolling/`.
The comment policy in [standards.md](standards.md#comments) is deliberately not among its rules.

## Formatting

```sh
./scripts/format.sh            # format Ollie/ and Tests/ in place
./scripts/format.sh --check    # report what would change, write nothing (exit 1 if any)
```

`swift-format` from the Xcode toolchain — the same binary sourcekit-lsp formats with, so ⌘S in VS Code
and this script cannot disagree. `.swift-format` at the repo root tunes it to this tree; without it the
stock config defaults to 2-space indent and rewrites all 200 files.

Every `*.generated.swift` file is excluded: formatting one is hand-editing it, and the next
`node scripts/gen-emoji.js` would revert it. swift-format also refuses any file that does not parse, so
a failure from either command is a syntax error rather than a tooling problem — and it is why ⌘S looks
like it does nothing while a file is mid-edit with unbalanced braces.
The two protected scrolling primitives, `EdgeDissolve.swift` and `ThinScrollbar.swift`, are also excluded.

**Think twice before leaning on this.** A formatter was rejected here on measured evidence, and that
stands: running it over the tree touched 68 files, and 67 of those changed more than whitespace.

The config sticks to rules that catch defects and stays quiet about style, because **there is no
formatter**, on measured evidence. Formatting is
Xcode's re-indent (⌃I), as it always has been. Two consequences worth knowing:

- `empty_count` is **disabled**, and `isEmpty`-style rewrites are unsafe here generally:
  `LauncherRankingRecord` and `PaletteRowIndex` have a `count` that is a hit count, not a collection
  count. A rule that rewrites `count > 0` to `!isEmpty` on them does not compile.
- `force_try` is an error; `force_cast` only warns, because the AX and AppKit bridges have four
  legitimate ones.

Errors block, warnings do not. No CI runs this script; CodeRabbit runs SwiftLint on each PR but not
the settings-search check, so run it locally before you open one.

## Generated data

Three Swift files are emitted by scripts and must never be hand-edited. Each downloads its source, so
run them online, then commit the result:

```sh
node scripts/gen-emoji.js            # -> Ollie/Features/Emoji/Model/EmojiData.generated.swift
                                     #    + Ollie/Resources/EmojiKeywords/<language>.txt
node scripts/gen-currencies.js       # -> Ollie/Features/Calculator/Model/CurrencyData.generated.swift
node scripts/gen-countries.js        # -> Ollie/Features/Calculator/Model/CountryZoneData.generated.swift
```

`gen-emoji.js` also writes one CLDR keyword pack per language in its `KEYWORD_LOCALES`; adding a
language is one line there. Pass a directory to keep the downloads between runs:
`node scripts/gen-emoji.js /tmp/emoji-sources`.

`gen-countries.js` joins IANA's `zone.tab` with CLDR's `en` territory names on the ISO 3166 code. Re-run
it when IANA adds or moves a country's zone; see [calculator.md](features/calculator.md#time-zones).

`gen-currencies.js` joins three sources on the ISO code: the **fiat rate feed**'s own quote list — the
same feed `CurrencyRateStore` fetches rates from, so the table and the rate source cannot drift apart
— **Unicode CLDR**'s `en` currency data, which supplies display names, signs and the singular/plural
noun, and **CLDR's supplemental currency data**, which says which codes are still spent anywhere. That
last one is not optional: the feed carries no retirement metadata and quotes codes their countries
abandoned years ago. Both CLDR files are read from the pinned `cldr-json` checkout rather than the
host's `Intl`, whose output shifts with the local ICU version and would make the file unreproducible.

Only unambiguous data is emitted. Anything two currencies claim — `dollars`, `pounds`, `krona` — is
left out and decided by hand in `CalcCurrency.contested`. The crypto tickers aren't generated at all:
they have no external source of truth, so `CalcCurrency.crypto` is hand-written, and that same list is
the set of symbols the fetch asks for. Re-run the script when a currency is added or retired; nothing
breaks in the meantime, since an unquoted code just reports "no exchange rate".
