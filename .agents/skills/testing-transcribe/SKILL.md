---
name: testing-transcribe
description: How to drive and verify end-to-end tests of the Transcribe macOS dictation app (test PCM feed, hotkey via test CLI, append-only paste log strings, TextEdit focus)
---

# Testing the Transcribe macOS app end-to-end

## Prerequisites (normally already provisioned — verify, don't rebuild)
- Signed app at `.xcdd/Build/Products/Debug/Transcribe.app`, running via
  `open -n -W --stdout /tmp/app.out --stderr /tmp/app.err <path>` (stdout is
  unbuffered — logs stream live). Check `pgrep -f MacOS/Transcribe`.
- `launchctl getenv TRANSCRIBE_TEST_PCM` points to a raw Float32-LE 16 kHz mono
  PCM file; set with `launchctl setenv TRANSCRIBE_TEST_PCM /tmp/voice_var.pcm`.
  The env var is captured at process launch: after changing it, `pkill -f
  'MacOS/Transcribe'` and relaunch or the old feed is still used.
- Feeds on this machine (regenerate with `transcribe-test feed <out> <mode>` if
  /tmp was wiped): `/tmp/voice_var.pcm` (8.7s → ~124 chars), `/tmp/zh.pcm` (4.5s
  Chinese → 66 chars), `/tmp/voice_mega.pcm` (37s, resyncs → ~497 chars),
  `/tmp/voice_huge.pcm` (117.7s, many resyncs → ~1735 chars), `/tmp/sparse.pcm`
  (28s → ~151), `/tmp/noise.pcm` (12s → empty), `/tmp/silence.pcm` (10s → empty).
- App must be Accessibility-trusted (event tap only). Signing identity "Devin
  Test Signing" — trust survives rebuilds.
- **Hotkey driver: `AlexTranscribeKit/.build/debug/transcribe-test hotkey`** —
  posts keyCode 176 via CGEvent from a CLI. Do NOT use `open ~/Applications/
  TTA.app`: launching a second app bundle bounces TextEdit's front document and
  splits the dictation across docs (harness artifact, not a product bug).
  Rebuild the CLI with `cd AlexTranscribeKit && swift build` (~21s).

## Architecture being verified (append-only paste pipeline)
- Committed words are pasted into the focused field as they commit
  (plain-text ⌘V; clipboard snapshotted/restored around each chunk, ~90ms).
- The volatile tail never enters the field — it decodes once at stop, lands as
  one final chunk. Final transcript also goes to the clipboard.
- There is no AX insertion path anymore. One bounded 0.5s caret probe on the
  first chunk decides boundary spacing; its failure just defaults to a leading
  space. Paste follows focus — chunks land wherever the caret is (dictation-app
  standard); a mid-dictation focus switch splits delivery across fields by
  design, clipboard keeps the whole transcript.

## Log strings (stdout /tmp/app*.out)
- `[insert] append +N chars (total M)` — a chunk pasted; total = emitted text len.
- `[insert] final text diverged ...` — contract violation or external field
  edit; investigate (should not appear in clean runs).
- `[stream] Nw committed / M shown (match k@s, +e)` — tick bookkeeping.
- `[stream] alignment resync after 3 misses` — stress feeds produce several.
- `[transcribe] tail decode: win=..., committed=A/Bw, hyp="..."` — normal finish.
- `[transcribe] N resyncs — full decode` — backstop path (mega/huge feeds).
- `[finish] text=...` — the exact final transcript.
- `[transcribe] copied N chars to clipboard; delivery=paste|nothing` — end.
  `nothing` = empty transcript; clipboard is preserved untouched.

## Drive script
`/tmp/drive.sh <feed> <recsecs> <finishwait> <tag>` relaunches the app on a
feed, dictates, then diffs front doc vs clipboard (byte-identical modulo the
trailing newline osascript adds). Recreate it from session history if missing.

## Verification rules
- PASS = doc text == clipboard text byte-for-byte. Read docs via
  `osascript -e 'tell application "TextEdit" to get text of front document'`
  (background with `&` — TextEdit reads can stall ~60s; it accumulates ~150
  stale "Untitled N" docs, so always `make new document` and read the front one).
- Chrome/web fields: verify visually via `screencapture -x /tmp/x.png` (no AX
  reads of web content needed — paste works without trust).
- Empty transcript (noise/silence): doc must stay untouched AND clipboard must
  keep its previous contents — never assert clipboard is empty.
- Hotkey presses during secure input (password prompts, Terminal secure entry)
  are hidden by macOS by design — detected and logged, recovers on release.
