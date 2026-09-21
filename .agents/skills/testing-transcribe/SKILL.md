---
name: testing-transcribe
description: How to drive and verify end-to-end tests of the Transcribe macOS dictation app (test PCM feed, TTA.app hotkey, log strings, TextEdit AX focus, known event-tap flake)
---

# Testing the Transcribe macOS app end-to-end

## Prerequisites (normally already provisioned — verify, don't rebuild)
- Signed app at `.xcdd/Build/Products/Debug/Transcribe.app`, running via
  `open -n -W --stdout /tmp/app.out --stderr /tmp/app.err <path>` (stdout is
  unbuffered — logs stream live to /tmp/app.out). Check `pgrep -f MacOS/Transcribe`.
- `launchctl getenv TRANSCRIBE_TEST_PCM` should point to a raw Float32-LE 16 kHz
  mono PCM file; if unset: `launchctl setenv TRANSCRIBE_TEST_PCM /tmp/voice16k.pcm`.
  When set, the app drips that file into the recorder at real-time pace instead of
  the mic — no audio device or mic permission needed. The env var is captured at
  process launch: after `launchctl setenv` to a different feed, `pkill` and relaunch
  the app or the old feed (or mic path) is still used. Other feeds seen on this
  machine: `/tmp/voice_var.pcm` (~12.4s varied speech), `/tmp/voice_long.pcm`
  (~26.8s repeated phrase — resync stress), `/tmp/silence.pcm` (5s zeros — empty
  transcript path).
- App must be Accessibility-trusted (System Settings → Accessibility row) — both
  the CGEvent key tap and AX text insertion depend on it. Signing identity is
  "Devin Test Signing" so trust survives rebuilds.
- Hotkey trigger: `open -W --stdout /tmp/tta.out ~/Applications/TTA.app --args hotkey`
  posts keyCode 176 down+up; the app's tap toggles record/stop. TTA.app wraps the
  `transcribe-test` CLI (`hotkey`/`feed`/`stream`/`focus`/`insert`/`live` modes).

## How to exercise the feature
1. Focus a text field first (e.g. fresh TextEdit doc, click into the text area) —
   AX writes go to whatever element is focused at each emission; keep focus there
   for the whole recording. Don't click elsewhere mid-run.
2. Post the hotkey once to start; the 184-pt overlay panel slides down top-center
   with particles; `[record] test feed started (N samples)` appears in /tmp/app.out.
3. Partial transcripts stream into the focused field while recording (each tick
   re-transcribes the growing buffer every ≥1.8 s of new audio; partials revise
   in place via AXSelectedText/AXSelectedTextRange — later writes replace the
   app's own tracked range, never duplicate).
4. Post the hotkey again to stop: `[record] captured Xs`, then
   `[transcribe] copied N chars to clipboard; delivery=accessibility`
   (`delivery=pasteFallback` + one ⌘V if the field refuses AX writes). Overlay
   hides; `pbpaste` holds the final transcript (trailing `.`/`。` stripped).

## Extended battery (added after local-agreement rewrite)
- **Mid-doc insertion**: click into the text area first (arrow-key AppleScript
  does not move the caret unless the text area is focused). Verify with
  `[insert] first write: sel=<loc>+<len> caret=<n>` in /tmp/app.out — loc must
  match where you clicked. Dictation auto-inserts a boundary space on each side
  when the caret sits against non-space text.
- **Selection replace**: select text via `key code 124 using shift down` repeats,
  confirm with `AXSelectedText` — dictation replaces the selection.
- **Focus switch mid-record**: AXRaise another TextEdit window mid-feed; the old
  doc keeps its frozen partial, the new doc receives the full transcript at its
  caret (`[insert] first write` appears again for the new element).
- **Hotkey spam during final decode**: presses are ignored (no `[record]`
  markers between `captured` and `copied`); the next press after `copied`
  starts a clean session.
- **Silence feed** (`b'\x00'*N` PCM): transcript is empty — clipboard must NOT
  be clobbered and no ⌘V is posted (log still says `delivery=pasteFallback`).
- **Pathological repeated audio** (concat the same phrase 3×): expect
  `[stream] alignment resync after 3 misses` lines — resyncs replace the tail
  only, never commit. Final doc must equal `pbpaste` byte-for-byte; a
  `[insert] tracked-range verify/write failed` line means the doc was left
  divergent (that was the resync-commit bug — fixed).
- Sequenced dictations in one doc anchor at the end-of-text caret
  (`sel=<N>+0 caret=<N>`) with auto-space, so N sessions produce N
  space-separated transcripts.
- Debug prints in LiveTextInserter (`[insert] focused el role=…`, `first write`,
  `tracked-range verify/write failed`) are load-bearing for these tests — keep
  them while testing.

## Gotchas observed
- The CGEvent tap can be disabled by timeout — log shows `event type:
  4294967294 keyCode: 0` (kCGEventTapDisabledByTimeout) and the posted hotkey is
  silently dropped. The callback doesn't re-enable the tap. Just re-post the
  hotkey via TTA.app — in practice the tap recovers and the retry lands.
- Model is unloaded after every transcription ("Removing transcriber"), so each
  record→stop cycle pays the full model-load cost before the first tick — with an
  ~9 s feed the first tick may only run near/after feed end, so mid-recording
  partials may appear late and as few revisions (not the "Hello" → "Hello, world"
  multi-step progression a warm model would show).
- osascript can be slow/blocked on first automation use against TextEdit; it did
  eventually succeed. Reading the doc's text via
  `osascript -e 'tell application "TextEdit" to get text of document "Untitled N"'`
  is authoritative for content assertions (screenshots at small size make
  ",worid"-vs-", world" spacing unreadable — crop/zoom full-res PNGs instead).
- Saved screenshots are full display resolution (e.g. 1568×1200) even though the
  computer tool uses 1024×768 coordinates — crop files with `sips` for legible
  text evidence.
- Mid-stream partials may carry raw decode spacing quirks ("Hello ,worid ! …");
  the final `inserter.finish` write replaces the whole range with the clean
  transcript — verify final text byte-for-byte, not by eyeballing partials.

## Devin Secrets Needed
- None for the app test path. (Mic permission isn't needed when
  TRANSCRIBE_TEST_PCM is set; if a TCC mic prompt appears, click "Don't Allow".)
