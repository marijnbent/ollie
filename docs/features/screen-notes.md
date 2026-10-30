# Screen notes

## Invariants

- `AppCore` owns `ScreenNoteCoordinator`. Screen Notes starts disabled and requires enabled, configured,
  idle Dictation. Speech uses the existing microphone, provider and language without per-app enhancement.
- A screen note is a finite session of screenshots and speech. Nothing is recorded between sessions,
  and screenshots stay local until the user pastes them. There is no video or continuous capture.
- Dictation hand-off returns text without clipboard writes or synthetic paste. The transcript and raw
  recording follow the existing Dictation history policy.
- Overlays never become key. Normal typing, app switching and Space switching remain with the active
  app. Overlays are always click-through and cover all connected displays.
- Cancelling, disabling either required feature, display changes, sleep and session deactivation cancel
  pending work and leave the clipboard unchanged. Asynchronous work is bound to its session ID.
- Capture is bounded to 20 screenshots and 64 MB of PNG data, with a 2560-pixel edge limit.
  Automatic context shots reserve three slots; markers reserve the final slot. Pen strokes are
  bounded to 4096 points. Queued captures count toward admission limits.
- Off means no capture, display links, panels, tasks or observers. Published clipboard files remain
  available for a later paste; the next successful note replaces old output files.

## One shortcut

Enable **Screen Notes** and configure **Dictation** in Settings → Features. Bind **Screen Note** in
Settings → Screen Notes. The same command is available in the launcher and menu bar.

Press the shortcut to start talking. Ollie takes a clean screenshot of the display under the pointer
and shows a recording widget there with Dictation's glass card, live audio orb and Widget position,
plus a screenshot count, Cancel and Finish. Dictation's own widget stays hidden during the session.

Hold **⇧ and move the pointer** to draw a red line on any display; no click is needed, and the ⇧ keycap in
the widget turns red while drawing. Releasing Shift saves one annotated screenshot and fades the line.
Pressing Shift without moving 4 pt, with another modifier, or while a mouse button is down, draws nothing, so typing capitals
and Shift-click selections are unaffected. There are no tools, ink settings or Snap button.
Screenshots use a background requested when the line starts, with the stroke composited on release.
Pending backgrounds and output stay bound to that stroke, even when a later capture completes first.

Use apps normally between lines. App and Space changes record a new narration context immediately,
then schedule a clean screenshot after 500 ms, merging rapid captures. Keeping the pointer on another
display for 500 ms, or drawing on it, changes the narration context too. App changes choose the
display containing the largest part of the frontmost window, falling back to the pointer display.

Press the shortcut again, press Super Caps Lock (⌃⌥⇧⌘), or click Finish, to stop narration. Ollie captures the final context,
omits an unchanged background, waits for transcription and copies one screen note to the clipboard.
It never pastes or submits a prompt. Cancel, or Esc while recording, leaves the clipboard unchanged.
Esc follows Dictation's Esc-to-cancel setting; other Dictation hotkeys are suspended for the session. A partial transcription or failed capture is reported; screenshots are still copied if speech fails.

Screen Recording is requested only when starting a session. Drawing reads the pointer and Shift
state on each display-link frame, so it needs no event monitor or Accessibility access.
Microphone access and speech credentials come from Dictation.

## Pasting

Finish writes one plain-text item, separate PNG items with PNG bytes and file URLs, and a `Note.md`
file. The note contains narration grouped by app/display context and linked to the closest screenshot
within that context, plus the complete transcript and screenshot timeline. Returning to an earlier
app starts a separate context, so its two visits cannot share narration accidentally.

Speech timestamps come from the provider's audio timeline, anchored to the actual recording start
and re-anchored on reconnect. Receipt time is never used: a delayed final result can still refer to
an earlier screen. Deepgram, ElevenLabs and AssemblyAI provide word timings; Muse provides utterance
ranges, which can refer to multiple contexts. ElevenLabs hand-off requests timestamps and waits for
the delayed timestamped commit before closing. Normal Dictation keeps its existing delivery timing.

Each exported PNG also has a footer with the nearby timed narration, app and display. The screenshot
pixels remain at their original scale above that footer. This preserves the spoken explanation even
in composers that import only images. Speech without usable timing stays in the full transcript;
the first PNG includes that complete session narration when timed image captions do not cover it.
There is one clipboard write and one user paste; destination apps control which representations they
accept. There is no destination-specific automation or additional copy command.

PNG and note files live in the bundle-specific `Caches/ScreenNotes/<session UUID>/` directory with
owner-only permissions. Cancelled output is removed after pending writes finish. Published files
survive closing Ollie because file URLs may be read later. The next successful note removes older
session directories; cancelling a new session preserves the previously copied files.

## Implementation and verification

`ScreenInk` and `ScreenNote` are pure models. `ScreenInkView` reads the pointer through a display link
and incrementally appends a native shape layer path. `ScreenNoteCapture` uses macOS 26's `SCScreenshotManager`, excluding only the feature's
control windows so ordinary Ollie windows can also be explained. PNG composition, encoding, text footers and
fingerprinting run off-main. Output work is serialized and screenshots are bounded before admission.

This independent native implementation is inspired by [Scrawl](https://github.com/kitlangton/scrawl).
Opus consultation recommended one shortcut, a held modifier for markers, automatic context
screenshots and the existing dictation hand-off. No third-party dependency is added.

`screen-ink-test` covers marker geometry, bounds, capture-slot reservation, display selection and
speech association across app/display changes and return visits. `transcription-timing-test` checks
ElevenLabs's delayed timestamped commit and incomplete word metadata. `ollie-dictation-test` verifies
recording-clock anchoring, late final speech and reconnect offsets. `screen-note-clipboard-test`
checks a private pasteboard and uses OCR on synthetic exported PNGs to prove they contain the correct
spoken words even when text and note-file items are ignored.
Live capture, Shift drawing without focus changes, app/Space switching and pasting into AI apps require
desktop-test approval; the noninteractive harnesses do not establish those behaviors.
