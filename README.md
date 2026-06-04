# AlexTranscribe

Pure-Swift speech-to-text running **`mlx-community/Qwen3-ASR-1.7B-8bit`** on Apple
Silicon via [mlx-swift](https://github.com/ml-explore/mlx-swift). No Python, no
`mlx-audio` — the model architecture, audio feature extraction, and tokenizer are all
reimplemented in Swift.

## Layout

- **`AlexTranscribeKit/`** — a SwiftPM package containing all the work:
  - library product `AlexTranscribeKit` (the model + a public `AlexTranscriber` API)
  - executable product `alex-transcribe` (CLI)
- **`AlexTranscribeApp.xcodeproj` + `App/`** — a no-op macOS app that links the kit so the
  transcription function is callable from an app. The app does nothing on screen.

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

The audio tower runs in full precision; the text decoder + token embedding are 8-bit
affine-quantized (group size 64), matching the checkpoint layout.

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

## Notes

- The bundled `Samples/voice.mp3` is actually a 24 kHz PCM WAV with an `.mp3`
  extension — Core Audio refuses it by extension, so a small WAV parser handles it and
  resamples to 16 kHz.
- Language is auto-detected (the model emits `language <X><asr_text>…`, which is
  stripped from the final output).
