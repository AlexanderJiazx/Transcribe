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
- **Focus round-trip (A→B→A)**: each field's anchor is saved on focus-leave and
  restored on return (`focused el … (resumed)` log); the first write back
  rewrites the stale span wholesale (keep=0). Regression check: A must end
  byte-equal to pbpaste — a `partial + full` doubled doc is the old bug.
  Focus moving to a non-text surface (Finder, desktop) never changes the
  anchor — updates continue into the already-anchored field.
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
- **Web fields (Chrome)**: AXSelectedText writes into Chromium web text fields
  return success but never reach the DOM ("evaporated"). The inserter verifies
  each first-write/append landed (read-back or caret advance) and prints
  `[insert] write evaporated — element not AX-writeable`; delivery falls to
  `pasteFallback` and ⌘V pastes the final transcript. Password fields can drop
  the synthetic ⌘V too — transcript still lands on the clipboard. To make
  Chrome expose its web AX tree at all, set `AXEnhancedUserInterface` on the
  process first (`System Events` attr) and click into the field.
- **Spotlight** (`key code 49 using command down`): live AX insertion works —
  transcript streams into the search field.
- **Select-all then dictate**: `first write: sel=0+<docLen>` replaces the whole
  selection — same as typing.
- **Scrolled-away caret**: insertion is coordinate-free — text lands at the
  caret even when the doc is scrolled so the caret is off-screen.

## Gotchas observed
- The CGEvent tap can be disabled by timeout (`event type: 4294967294` in the
  log = kCGEventTapDisabledByTimeout) or silently die (zero events delivered,
  no error). The callback re-enables on disable events, and a 1.5s watchdog
  posts a flagsChanged probe (keyCode 58, option-release — inert if leaked)
  through the tap; if no event is delivered between ticks the tap is rebuilt
  (`CFMachPortInvalidate` + recreate). Test args: `--tap-disable-test` forces
  `CGEvent.tapEnable(false)` at +4s, `--tap-kill-test` invalidates the port at
  +4s (both fire once per process lifetime).
- `AXUIElementIsAttributeSettable` on the focused element can transiently FAIL
  while the target app's AX server is busy — the inserter therefore only checks
  settability when adopting an element, and writes to the adopted anchor
  without re-checking. Before this fix, a mid-stream flake froze the document
  at a partial transcript (236/697 chars on the 57s feed) with zero errors.
- Two-step tracked writes (`AXSelectedTextRange` then `AXSelectedText`) can
  race: the selection may apply asynchronously and the text write lands as an
  append at a stale caret — duplicating tail fragments. The inserter now
  confirms the selection (`selectionIs`) before writing and post-verifies the
  doc-length delta + content; a misplaced write is repaired by deleting the
  stray tail copy and rewriting the span.
- `finish()` reports pasteFallback when `lastInserted` lags the final text —
  the caller pastes the complete transcript rather than leaving a truncated
  document. Check /tmp/app.out for `[insert] final text not delivered`.
- ⌘Z mid-dictation undoes tracked writes one step at a time; the field can be
  left holding an earlier revision. appendDelta detects the stale span (long
  shared prefix with current text, but not `hasPrefix(lastInserted)`) and
  rewrites it — verified byte-clean after a double-⌘Z.
- Secure event input (password field focused): the field is invisible to AX or
  non-settable → updates drop (`[insert] focused element not text-settable`),
  pasteFallback's synthetic ⌘V is dropped by secure input — correct: nothing
  lands, transcript stays on the clipboard. Secure input does NOT wedge the
  hotkey tap afterward (verified: next dictation into TextEdit works).
- A modal dialog stealing focus mid-dictation (e.g. ⌘S save panel) counts as a
  new writeable focus — dictation follows into the filename field by design.
  First-launch modals ("Welcome to Freeform/Reminders", iCloud prompts) are
  non-settable: updates drop (`focused element not text-settable`), finish
  degrades to pasteFallback, and ⌘V goes nowhere — clipboard still complete.
  Freeform canvas text boxes are the same shape: not AX-settable, but ⌘V
  delivers the full transcript into the box. Reminders' new-item row DOES take
  live AX once real focus is on the row (⌘N opens it).
- `osascript` doc reads race `pbpaste` less than a second-old clipboard write;
  if `diff` shows doc≠clip, re-read pbpaste before suspecting corruption.
- **Own-overlay focus**: at launch our fringe NSPanel can hold key status, so the
  system focused element can be OURS — the inserter filters by pid and uses the
  menu-bar-owning app's focused element instead (`menuBarOwnerElement`). Same
  fallback on transient non-text focus (banners). Log: `[insert] focused el is
  ours` / `using menu-bar owner's focused el`.
- **Secure input lifecycle**: while another app holds Secure Event Input
  (Terminal Secure Keyboard Entry, password fields), key events are hidden —
  the tap looks dead but isn't. Watchdog logs `secure event input held by
  another app — hotkey hidden until released` then `secure input released —
  hotkey restored`. Presses during the window are unrecoverable by design.
- **Final pass**: `resyncCount ≥ 3` → full decode of the whole buffer
  (authoritative, ~40s on a 172s feed); otherwise a bounded tail decode +
  `applyFinalWindow` splice. Watch `[stream] N resyncs — full decode` and
  `[stream] final pass: tail decode`. After a session that resynced, the doc
  must still end byte-equal to pbpaste — a doubled transcript means
  `spliceAnchor`/`committedSuffixOverlap` regressed (both are subsequence-based;
  verify against /tmp/voice_mega.pcm = 697 chars).
- **Single instance**: a second app copy exits(0) at launch (`another instance
  running — exiting`); old betas left running will not double-transcribe.
- Feed files on this machine: /tmp/voice_var.pcm (12.4s, 202 chars),
  /tmp/voice_mega.pcm (57.3s, 697 chars authoritative), /tmp/voice_huge.pcm
  (172s, 1862 chars), /tmp/zh.pcm (Chinese, 45 chars), /tmp/gap.pcm (~30s,
  speech-gap-speech), /tmp/silence.pcm, /tmp/nums.pcm (10.5s numbers/dates,
  178 chars), /tmp/sparse.pcm (29.6s — 0.55s speech / 0.75s silence bursts;
  drives ≥3 resyncs → exercises the full-decode backstop), /tmp/quiet.pcm and
  /tmp/loud.pcm (var at 5%/8× amplitude — both decode identical to var).
- **Xcode source editor** takes live AX dictation (AXTextArea, settable) —
  verified end-to-end. **App Store search field** takes live AX too (reads
  via AXValue; System Events can't find it in the flat hierarchy — verify by
  Home-key scrollback in the field). **Prepend at caret 0** works.
- **Reminders ⌘N title field** takes live AX, but during Reminders'
  cold-start its shared field editor can silently rebind to a NEW item when
  the title commits — our writes keep landing via the same AX element so
  post-verify reads the rebound doc, and the stale item keeps whatever it
  had (observed once: an item holding transcript+transcript). Undetectable
  from the inserter; treat as an app quirk, not a code bug.
- Beta packaging: adhoc (`codesign -s -`) changes the cdhash every build →
  TCC re-prompts Accessibility/Mic each release. Sign betas with
  "Devin Test Signing" instead so grants persist across versions.
- `[insert] write @<loc>+<len> keep=<k> newLen=<n> docLen=<d>` logs every
  tracked write — use it to reconstruct exactly what landed where.
- The ASR model is loaded once at launch on transcribeQueue and stays resident
  across dictations (reloading per session leaked ~15 MB of MLX descriptors and
  added load latency). `[record] model loaded` appears shortly after launch; the
  first dictation is still tick-gated by available audio, not model load.
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
- **SIGSTOP the app mid-dictation** (`kill -STOP/-CONT <pid>`) freezes the audio
  drip and lags `committedEndSample` → the tail decode window can cover the WHOLE
  recording and its hyp may *insert* words the live ticks dropped. The final
  splice must tolerate hyp-side insertions (symmetric subsequence skip) — a
  doubled transcript like `…newest words. This is a test…` means the matcher
  regressed (was pinned on the inserted word). Reproduced and fixed in d959e1e.
- **Chrome omnibox** takes live AX (AXTextField settable; ⌘L selects the URL,
  first write replaces the selection). **Chrome `contenteditable` divs**
  (file:// test page) are invisible to the system focused-element query →
  `no focused element` drops → pasteFallback ⌘V lands the full transcript —
  same shape as textarea/input.
- **Format→Make Plain Text mid-dictation** recreates the doc but TextEdit keeps
  the same NSTextView — writes continue uninterrupted.
- **Target app killed during final decode**: `[insert] write evaporated` →
  `final text not delivered` → pasteFallback ⌘V lands wherever focus went
  (harmless); clipboard still holds the full transcript.
- Notes **table cells** are invisible to the system focused-element query →
  `no focused element` → pasteFallback ⌘V lands inside the cell correctly.
- **Never `lldb -p` a running Transcribe** — the manual codesign omits
  `get-task-allow`, so the kernel SIGKILLs the process on debugserver attach
  (unified log shows `task_for_pid` + `ptrace(PT_ATTACHEXC)` at the death
  instant, no crash report). Use `sample <pid>` instead — it works without
  Developer Tools auth. An attach attempt also spawns a hidden SecurityAgent
  "Developer Tools Access" prompt that holds secure input and can't be clicked
  away synthetically — answer it by typing the account password + Continue.
- **No-input-device start**: on a Mac with zero audio input devices,
  `engine.inputNode` returns a phantom `2ch 44100Hz` format and `installTap`
  raises `com.apple.coreaudio.avfaudio` NSException — uncatchable in Swift,
  **swallowed by the main-runloop handler** (HIServices FAULT in unified log),
  leaving the Task dead mid-flight and the overlay expanded forever. Repro:
  granted mic + unset TRANSCRIBE_TEST_PCM + press → last log is
  `[rec] input format …`. Fixed: `start()` enumerates input devices first and
  throws `[rec] no audio input devices` → `couldn't start` → overlay aborts +
  alert. `[rec] …` prints are intentional start-path breadcrumbs.
- **Mic TCC grant requires Quit & Reopen** to take effect in a running app;
  a revoked Accessibility grant recovers live (watchdog retry re-creates the
  tap ~10s backoff). `tccutil reset Accessibility com.alexanderjia.app.transcribe`
  revokes mid-run for the revoke-recovery test; `AXIsProcessTrusted` reads
  stale-true afterward — `CGEvent.tapCreate` failure is the real revoked signal.

## Devin Secrets Needed
- None for the app test path. (Mic permission isn't needed when
  TRANSCRIBE_TEST_PCM is set; if a TCC mic prompt appears, click "Don't Allow".)
