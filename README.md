# AlexTranscribe

Pure-Swift speech-to-text running **`mlx-community/Qwen3-ASR-1.7B-8bit`** on Apple
Silicon via [mlx-swift](https://github.com/ml-explore/mlx-swift). No Python, no
`mlx-audio` — the model architecture, audio feature extraction, and tokenizer are all
reimplemented in Swift.

## Layout

- **`AlexTranscribeKit/`** — a SwiftPM package containing all the work:
  - library product `AlexTranscribeKit` (the model + a public `AlexTranscriber` API,
    `LiveTextInserter` for live AX insertion)
  - executable products `alex-transcribe` (CLI) and `transcribe-test` (test harness)
- **`Transcribe.xcodeproj` + `App/`** — the dictation overlay app: a global hotkey
  (dictation key, keyCode 176) toggles recording, which now transcribes **while you
  speak** and types the partial transcript straight into the focused field via the
  Accessibility API.

## What's implemented

All in `AlexTranscribeKit/Sources/AlexTranscribeKit/`:

| Piece | File |
|------|------|
| Public API façade (`AlexTranscriber`) | `AlexTranscribeKit.swift` |
| Config parsing (`config.json`) | `Config.swift` |
| Byte-level BPE tokenizer (`vocab.json` + `merges.txt` + special tokens) | `Tokenizer.swift` |
| Audio decode (WAV parser + AVFoundation fallback) + Whisper 128-bin log-mel (STFT via MLX FFT, slaney mel filterbank) | `AudioFeatures.swift` |
| Audio encoder: Conv2d frontend, chunking, sinusoidal pos-emb, 24 transformer layers w/ block attention, proj head | `AudioEncoder.swift` |
| Qwen3 text decoder: 8-bit quantized linears/embedding, RMSNorm, Q/K-norm, GQA, RoPE, KV cache, tied LM head | `TextDecoder.swift` |
| Weight load/quantize, audio-embed splice, greedy generation | `Qwen3ASR.swift` |
| Live insertion into the focused text field via `AXSelectedText` | `LiveTextInserter.swift` |

The audio tower runs in full precision; the text decoder + token embedding are 8-bit
affine-quantized (group size 64), matching the checkpoint layout.

## Real-time transcription + live insertion

The app no longer waits for "recording complete" to transcribe. While recording, a loop
on `transcribeQueue` re-runs the model over the growing capture every
`tickAudioInterval` (≈1.8 s) of new audio; `AlexTranscriber.transcribe` streams its
partial text out through `onPartialText` (emitted every few decoded tokens) and each
emission is written into the focused field immediately.

Insertion uses `LiveTextInserter` (`App` calls `inserter.update(partial)` per emission):

- First update anchors at the focused element's caret (`AXSelectedTextRange`) and writes
  via `AXSelectedText`.
- Later updates re-select the previously written range and replace it with the newer
  cumulative text, so mid-stream revisions are corrected in place.
- Before each replace the tracked range is read back (`AXStringForRange`); if the user
  edited inside our text, the inserter degrades to append-only diffs at the caret instead
  of clobbering it.
- If the focused element doesn't expose a settable `AXSelectedText` (secure fields,
  Terminal…), `finish(_:)` reports `.pasteFallback` — the app copies the transcript to
  the clipboard and posts a single ⌘V, matching the old behaviour.

The final transcript is always copied to `NSPasteboard.general` on stop, regardless of
which delivery path ran.

Two requirements for the AX path on a machine:

- **Accessibility permission** for the app (System Settings → Privacy & Security →
  Accessibility). The app already needs it for the global hotkey tap, so no extra grant.
- **An app context**: AX element queries return `kAXErrorAPIDisabled` from a bare
  process even when trusted — the AX connection only works once `NSApplication` (or the
  equivalent GUI-session setup) exists. The app always has this; CLI tools that want AX
  access must init it themselves.

## Calling it

```swift
import AlexTranscribeKit

// From an app: the model is bundled, so no paths to wire up.
let asr = try AlexTranscriber()                          // loads the bundled model
// Or point at an explicit directory (what the CLI does):
let asr = try AlexTranscriber(modelDirectory: modelDir)

let text = try asr.transcribe(audioURL: audioURL)        // from a file
let text = try asr.transcribe(audioData: data)           // from encoded bytes in memory
let text = try asr.transcribe(samples: pcm, sampleRate: 16000)  // from raw PCM in memory

// Streaming variant: partial text callbacks while decoding, plus cooperative cancel.
let text = try asr.transcribe(
    samples: pcm, sampleRate: 16000,
    onPartialText: { partial in updateUI(with: partial) },
    isCancelled: { shouldAbort })
```

The in-memory overloads (`audioData:` / `samples:`) avoid writing audio to disk before
transcribing — useful for recorded buffers or downloaded bytes. (WAV bytes are decoded fully
in memory; other compressed formats are briefly spilled to a temp file, since AVFoundation's
decoders need one.)

## Build & run

### macOS app (recommended — Xcode bundles the Metal shaders automatically)

```sh
# one-time: install the Metal Toolchain component (~700 MB)
xcodebuild -downloadComponent MetalToolchain

xcodebuild -project AlexTranscribeApp.xcodeproj -scheme AlexTranscribeApp \
  -configuration Debug -derivedDataPath .xcdd -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The built app at `.xcdd/Build/Products/Debug/AlexTranscribeApp.app` runs with the metallib
already bundled inside it. The `models/Qwen3-ASR-1.7B-8bit/` directory is added to the app target
as a folder reference, so the weights ship inside the app (`…/Resources/Qwen3-ASR-1.7B-8bit/`) and
`AlexTranscriber()` loads them automatically — the resulting `.app` is ~2.3 GB as a result.

### CLI

`swift build` alone cannot compile MLX's Metal shaders, so colocate the metallib that the
Xcode build produced next to the CLI binary:

```sh
cd AlexTranscribeKit
swift build --product alex-transcribe
cp ../.xcdd/Build/Products/Debug/AlexTranscribeApp.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
   "$(swift build --show-bin-path)/mlx.metallib"
cd ..

# run from repo root (defaults to Samples/voice.mp3; pass a path to transcribe another file)
"$(cd AlexTranscribeKit && swift build --show-bin-path)/alex-transcribe" [audio-file]
```

The model is expected under `models/Qwen3-ASR-1.7B-8bit/` (download from the HF repo of
the same name). Set `ASR_DEBUG=1` to print raw generated token ids.

### Test harness (`transcribe-test`)

`swift build --product transcribe-test` builds a CLI harness that exercises the
streaming + insertion paths without touching the app UI:

```sh
T=$(cd AlexTranscribeKit && swift build --show-bin-path)/transcribe-test

"$T" feed  audio.mp3 out.pcm        # decode → raw Float32-LE 16 kHz PCM
"$T" stream audio.mp3 [tickSec]     # replay streaming ticks over the file (partials printed)
"$T" focus                          # print the focused element (needs AX trust)
"$T" insert "text"                  # one-shot LiveTextInserter write at the caret
"$T" live "A" "AB" "ABC"            # cumulative updates 0.5 s apart (revisions in place)
"$T" hotkey                         # post the keyCode-176 toggle the app listens for
```

`TRANSCRIBE_MODEL_DIR` overrides the model location (default `./models/Qwen3-ASR-1.7B-8bit`).

The AX modes need Accessibility permission for whichever process runs them. When wrapped
in an `.app` bundle and launched via `open`, a GUI-session AX connection exists and the
writes land in the focused app.

### App end-to-end test seam

`TRANSCRIBE_TEST_PCM=<path-to-Float32-LE-16kHz-PCM>` makes the app feed that file at
real-time pace instead of the microphone (`recorder.start(testFeed:…)`), so the entire
hotkey → streaming → AX-insertion → clipboard path can be tested on machines with no
audio device:

```sh
launchctl setenv TRANSCRIBE_TEST_PCM /tmp/voice16k.pcm
open -n -W --stdout /tmp/app.log .xcdd/Build/Products/Debug/Transcribe.app
# press the dictation hotkey (or `"$T" hotkey` from a trusted process) to start/stop
```

## Notes

- The bundled `Samples/voice.mp3` is actually a 24 kHz PCM WAV with an `.mp3`
  extension — Core Audio refuses it by extension, so a small WAV parser handles it and
  resamples to 16 kHz.
- Language is auto-detected (the model emits `language <X><asr_text>…`, which is
  stripped from the final output).
