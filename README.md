# Ollie

A native macOS utility combining Ollie’s launcher, clipboard history and snippets, dictation,
window switching, narrated screen captures and temporary drawing, typing sounds, camera imports, ntfy notifications, and network usage.
Mailie stays separate. The launcher is forked from [Tinycast](https://github.com/abue-ammar/tinycast).

The menu is a compact strip of actions with live activity above it. Native grouped settings hold
independent feature switches, a shared shortcuts page, permissions, and explicit imports from the
original apps. Network provides monitoring; it does not claim to block connections.

Open Settings from the menu strip. New capture features start off. To bring over an existing app,
quit that app, import it under Settings → Backup, then enable the corresponding feature. Notification
topics import from the Notifications pane. Existing Ollie preferences stay in place.

Requires macOS 26+, Xcode 26, and XcodeGen (`brew install xcodegen`).

[Screen Notes](docs/features/screen-notes.md) combines existing dictation with annotated screenshots.
Enable it in Settings → Features, then use **Screen Note**: one shortcut starts narration, ⌥-drag
adds markers, and the shortcut again copies screenshots and the note for pasting into your agent.

## Build and install

The repository lives at `/Users/marijn/Projects/ollie`.

```sh
cd /Users/marijn/Projects/ollie
./scripts/release-local.sh
```

Quits Ollie if it is running, builds a signed Release bundle, verifies the bundle,
installs `/Applications/Ollie.app`, and opens it. Signing uses the existing Apple Development
identity recorded in `release/Release.plist`. A missing identity or signing failure stops the
release; there is no unsigned fallback.

Separate steps:

```sh
./scripts/build-release.sh
./scripts/install-release.sh
```

The build is at `build/Release/Ollie.app`. Version and build number live in `project.yml`.
For a signed disk image, run `./scripts/build-dmg.sh`.

## Development

```sh
xcodegen generate
xcodebuild -project Ollie.xcodeproj -scheme Ollie -configuration Debug build
./scripts/run-tests.sh
./scripts/lint.sh
```

The folder, source directory, Xcode project, target, scheme, and GitHub repository use Ollie.
Release retains `nl.bentjes.fredie`; Debug retains `nl.bentjes.fredie.dev` and is named `Ollie Dev`.
These internal IDs, bundle-scoped files and Keychain services, and `~/.config/fredie/settings.json`
(with channel suffixes) preserve existing settings, credentials, permissions, and login registration.
New backups use `.ollie`; an existing native archive can be renamed from `.fredie` to `.ollie` before import.
Preferences, files, permissions, URL scheme (`ollie://`), and backups are separate from Tinycast.
Update checks use only `marijnbent/ollie`. No Ollie GitHub release has been published yet.

See [unified app](docs/ollie.md), [development](docs/development.md), [release](docs/release.md), and [testing](docs/testing.md).
The inherited `website/` is upstream material, not a published Ollie website; its deployment
workflows remain restricted to the upstream repository.

## License and attribution

Ollie retains Tinycast's [AGPL-3.0 license](LICENSE), original copyright notices, and
[third-party notices](NOTICE.md). Tinycast was created by Abue Ammar. Core launcher features
are retained; Ollie uses its own Happy Pocket Otter app icon and outlined Cheeks otter menu mark.
In-app support links explicitly support the upstream Tinycast project.
