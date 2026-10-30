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
- Capture is bounded to ten screenshots and 32 MB of PNG data, with a 2560-pixel edge limit.
  Context shots reserve the final slot. The pointer track is bounded to 4096 samples and thins
  itself evenly when full. Queued captures count toward admission limits.
- Off means no capture, display links, panels, tasks or observers. Published clipboard files remain
  available for a later paste; the next successful note replaces old output files.

## One shortcut

Enable **Screen Notes** and configure **Dictation** in Settings → Features. Bind **Screen Note** in
Settings → Screen Notes. The same command is available in the launcher and menu bar.

Press the shortcut to start talking. Ollie takes a clean screenshot of the display under the pointer
and shows a recording widget there with Dictation's glass card, live audio orb and Widget position,
plus a screenshot count, Cancel and Finish. Dictation's own widget stays hidden during the session.

Point at what you are talking about. A thin red trail follows the pointer and fades within a
second; there is no modifier, click, drawing mode or Snap button. On export, each screenshot gets
the pointer path from the speech linked to it, on its display, so the image shows what each sentence
referred to. Movement while silent is not drawn.

Use apps normally while talking. App and Space changes record a new narration context immediately,
then schedule a clean screenshot after 500 ms, merging rapid captures. Moving the pointer to another
display and keeping it there for 500 ms changes the narration context too. App changes choose the
display containing the largest part of the frontmost window, falling back to the pointer display.

Press the shortcut again, or click Finish, to stop narration. Ollie captures the final context,
omits an unchanged background, waits for transcription and copies one screen note to the clipboard.
It never pastes or submits a prompt. Cancel leaves the clipboard unchanged. Normal Dictation hotkeys
and its Esc-to-cancel interception are suspended for the session so app-level
Escape remains usable. A partial transcription or failed capture is reported; screenshots are still copied if speech fails.

Screen Recording is requested only when starting a session. The trail reads the pointer position
on each display-link frame, so it needs no event monitor or Accessibility access. Microphone access and speech credentials come from Dictation.

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

`ScreenInk` and `ScreenNote` are pure models. `ScreenInkView` draws the trail into eight reused
shape layers grouped by age. `ScreenNoteCapture` uses macOS 26's `SCScreenshotManager`, excluding
only the feature's control windows so ordinary Ollie windows can also be explained. PNG composition,
pointer paths, encoding, text footers and fingerprinting run off-main. Output work is serialized and
screenshots are bounded before admission.

This independent native implementation is inspired by [Scrawl](https://github.com/kitlangton/scrawl).
No third-party dependency is added.

`screen-ink-test` covers pointer filtering and thinning, capture-slot reservation, display selection,
speech association across app/display changes and return visits, and pointer paths per screenshot.
`transcription-timing-test` checks ElevenLabs's delayed timestamped commit and incomplete word
metadata. `ollie-dictation-test` verifies recording-clock anchoring, late final speech and reconnect
offsets. `screen-note-clipboard-test` checks a private pasteboard and uses OCR on synthetic exported
PNGs to prove they contain the correct spoken words even when text and note-file items are ignored.
Live capture, the trail, display switching, focus preservation and pasting into AI apps require
desktop-test approval; the noninteractive harnesses do not establish those behaviors.
