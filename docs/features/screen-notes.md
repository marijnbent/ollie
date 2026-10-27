# Screen notes

## Invariants

- `AppCore` owns `ScreenNoteCoordinator`. Screen Notes starts disabled. Explain Screen also requires
  Dictation to be enabled and idle; drawing alone works independently of Dictation and Launcher.
- A screen note is a finite session of screenshots and speech, never a video stream. Screenshots stay
  local until the user pastes them. Speech uses the existing dictation microphone, provider and language.
- Dictation hand-off returns text without clipboard writes or synthetic paste. The transcript and raw
  recording follow the existing Dictation history policy. Per-app enhancement prompts are skipped.
- Cancelling, disabling either required feature, display changes, sleep and session deactivation cancel
  pending work and leave the clipboard unchanged. Every asynchronous result is bound to its session ID.
- Off means no capture, input listeners, panels, expiry task or observers. Published clipboard files
  remain available for a later paste; the next successful note replaces old output files.
- Capture is bounded to ten screenshots and 32 MB of PNG data. Screenshot edges are capped at 2560
  pixels. Ink is bounded to 128 finished strokes and 4096 points per pen stroke; arrows retain endpoints.

## Explain Screen

Enable **Screen Notes** and configure **Dictation** in Settings → Features. Start **Explain Screen**
from the launcher, the menu bar's options menu or its shortcut in Settings → Screen Notes.

The command chooses the display under the pointer. The Explain Screen menu in its settings selects
one display explicitly. Screen Recording permission is required and requested only by starting the
command. Existing microphone access and speech credentials are reused.

The session takes an initial clean screenshot, starts narration and shows a compact toolbar on that
same display. Drawing is optional: the cursor button releases mouse input to the app underneath,
so scrolling, clicking and app switching can continue while talking. The toolbar stays clickable.

**Snap** captures another screenshot with the current ink burned in, then removes only the captured
strokes. New strokes drawn during capture remain. Ink stays until captured or cleared during a narrated
session, so a temporary fade cannot silently remove annotations from the final screenshot.

**Done** (or Explain Screen's shortcut again) takes a final screenshot if capacity remains and waits
for speech finalization. It copies separate PNG files and the note to the clipboard and closes the
controls. It never pastes or submits a prompt. A partial transcription or failed screenshot is reported;
if speech fails, the screenshots are still copied with a notice.

| Control while drawing | Action |
| --- | --- |
| Drag / Shift-drag | Selected pen or arrow / temporary arrow |
| P / A | Select pen / arrow |
| 1–4 | Red / yellow / blue / green |
| [ / ] | Decrease / increase width |
| Space | Take screenshot |
| D | Toggle drawing and interaction with the underlying app |
| ⌘Z / Delete | Undo / clear ink |
| Return | Done |
| Esc, right-click or close button | Cancel without changing the clipboard |

## Pasting

Done writes one plain-text item containing the transcript and screenshot timestamps, followed by one
item per PNG with both PNG bytes and a file URL, and a `Note.md` file containing the same text. The note
file lets a composer that prioritizes file attachments still receive the explanation.

Paste handling belongs to the destination app. **Copy Last Screen Note** copies the complete result
again; **Copy Last Note Text** copies only text for a separate paste if the destination discarded it.
Both commands are bindable and appear in the menu-bar options and Screen Notes settings. They retain
only the latest completed note in this app session. No destination-specific automation is used.

PNG and note files live in the bundle-specific `Caches/ScreenNotes/<session UUID>/` directory with
owner-only permissions. Cancelled output is removed after pending writes finish. Successfully copied
files survive closing Ollie because pasteboard file URLs may be read later. The next successful note
removes older session directories; a cancelled new session preserves the previously copied result.

## Drawing alone

**Draw on Screen** opens the same native ink surfaces without microphone or screenshots, across all
displays. It needs no permissions. Escape, right-click, the close button or the command again closes
and clears the drawing. App or Space switching also closes this standalone mode.

Settings and toolbar options provide three widths and four colors. Drawing-only auto-clear is 2, 5 or
10 seconds, or Until closed. Defaults are red, medium pen strokes and five-second clearing. Narrated
sessions keep ink until Snap or Done instead. Tool, color, width, auto-clear and Explain Screen's
shortcut mirror through `settings.json` under `screenNotes`; the enable switch is never imported.

## Implementation and verification

`ScreenInk` and `ScreenNote` are pure models. `ScreenInkView` appends live paths incrementally and
uses one `CAShapeLayer` per stroke. `ScreenNoteCapture` uses macOS 26's `SCScreenshotManager`, excluding
only the feature's control windows, so Ollie's ordinary windows can also be explained. Image
composition and PNG encoding run off-main through `ScreenNoteImage`.

This independent native implementation is inspired by [Scrawl](https://github.com/kitlangton/scrawl).
Opus consultation recommended reusing dictation through a hand-off delivery mode, explicit drawing,
separate screenshots and no continuous recording pipeline. It adds no third-party dependency.

`ollie-dictation-test` covers hand-off delivery and abandonment while retaining normal dictation checks.
`screen-ink-test` covers ink expiry, undo, bounded storage, shot limits and point-to-pixel composition.
`screen-note-clipboard-test` verifies multi-item text, PNG and note-file output on a private pasteboard.
Live capture, microphone, focus return and pasting into AI apps require desktop-test approval and are
not established by those harnesses.
