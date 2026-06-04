import Foundation
import MLX
import MLXNN

final class Qwen3ASRModel: Module {
    let cfg: ModelConfig

    @ModuleInfo(key: "audio_tower") var audioTower: AudioEncoder
    @ModuleInfo(key: "model") var model: TextModel

    init(_ cfg: ModelConfig) {
        self.cfg = cfg
        _audioTower.wrappedValue = AudioEncoder(cfg.audio)
        _model.wrappedValue = TextModel(cfg.text)
        super.init()
    }

    /// Load (quantized) weights from a safetensors file.
    func loadWeights(safetensors: URL) throws {
        // Quantize the text decoder + embeddings (8-bit), leave the audio tower in full precision.
        let g = cfg.quantGroupSize, b = cfg.quantBits
        quantize(model: self, groupSize: g, bits: b) { path, _ in
            !path.hasPrefix("audio_tower")
        }

        var weights = try loadArrays(url: safetensors)
        weights.removeValue(forKey: "lm_head.weight")  // tied embeddings; not used

        let params = ModuleParameters.unflattened(weights)
        try update(parameters: params, verify: [.noUnusedKeys, .allModelKeysSet, .shapeMismatch])
        eval(self)
    }

    func audioFeatures(_ inputFeatures: MLXArray) -> MLXArray {
        audioTower(inputFeatures)
    }

    /// Build input embeddings, splicing audio features in place of audio-pad tokens.
    func inputsEmbeds(ids: [Int], audioFeatures: MLXArray) -> MLXArray {
        let idsArray = MLXArray(ids.map { Int32($0) })
        var embeds = model.embedTokens(idsArray)              // (L, hidden)
        let af = audioFeatures.asType(embeds.dtype)

        guard let start = ids.firstIndex(of: cfg.audioTokenId) else {
            return embeds.reshaped([1, ids.count, embeds.dim(1)])
        }
        let num = af.dim(0)
        let pre = embeds[0 ..< start, 0...]
        let post = embeds[(start + num) ..< ids.count, 0...]
        embeds = concatenated([pre, af, post], axis: 0)       // (L, hidden)
        return embeds.reshaped([1, ids.count, embeds.dim(1)])
    }

    func logitsForLast(_ hidden: MLXArray) -> MLXArray {
        let last = hidden[0..., (hidden.dim(1) - 1)..., 0...]  // (1,1,hidden)
        return model.embedTokens.asLinear(last)                // (1,1,vocab)
    }
}

struct Transcriber {
    
    let model: Qwen3ASRModel
    let tokenizer: BPETokenizer
    let mel = WhisperMel()
    let eosTokens: Set<Int> = [151645, 151643]

    /// Build the ASR prompt token ids (language auto-detect: empty assistant prefix).
    func buildPrompt(numAudioTokens: Int) -> [Int] {
        var ids: [Int] = []
        let imStart = tokenizer.specialId("<|im_start|>")
        let imEnd = tokenizer.specialId("<|im_end|>")
        let audioStart = tokenizer.specialId("<|audio_start|>")
        let audioEnd = tokenizer.specialId("<|audio_end|>")
        let audioPad = tokenizer.specialId("<|audio_pad|>")

        ids.append(imStart)
        ids += tokenizer.encode("system\n")
        ids.append(imEnd)
        ids += tokenizer.encode("\n")
        ids.append(imStart)
        ids += tokenizer.encode("user\n")
        ids.append(audioStart)
        ids += Array(repeating: audioPad, count: numAudioTokens)
        ids.append(audioEnd)
        ids.append(imEnd)
        ids += tokenizer.encode("\n")
        ids.append(imStart)
        ids += tokenizer.encode("assistant\n")
        return ids
    }

    /// Transcribe from disk
    func transcribe(audioURL: URL, maxTokens: Int = 4096, verbose: Bool = true) throws -> String {
        let audio = try loadAudio16kMono(url: audioURL)
        return transcribe(samples16k: audio, maxTokens: maxTokens, verbose: verbose)
    }

    /// Transcribe in-memory
    func transcribe(samples16k audio: [Float], maxTokens: Int = 4096, verbose: Bool = true) -> String {
        let t0 = Date()
        if verbose { print("audio: \(audio.count) samples (\(String(format: "%.2f", Double(audio.count) / 16000))s)") }

        let (feats, numFrames) = mel.features(from: audio)
        let numAudioTokens = featExtractOutputLength(numFrames)
        if verbose { print("mel frames: \(numFrames), audio tokens: \(numAudioTokens)") }

        // encode audio
        let audioEmb = model.audioFeatures(feats)
        audioEmb.eval()
        if verbose { print("audio encoded: \(audioEmb.shape)") }

        let promptIds = buildPrompt(numAudioTokens: numAudioTokens)
        let embeds = model.inputsEmbeds(ids: promptIds, audioFeatures: audioEmb)
        embeds.eval()
        if verbose { print("prompt tokens: \(promptIds.count)") }

        let caches = (0..<model.cfg.text.numHiddenLayers).map { _ in KVCache() }

        // prefill
        var hidden = model.model(inputsEmbeds: embeds, caches: caches)
        var logits = model.logitsForLast(hidden)
        var token = argMax(logits, axis: -1).item(Int.self)

        var generated = [Int]()
        let tPrefill = Date()
        for _ in 0..<maxTokens {
            if eosTokens.contains(token) { break }
            generated.append(token)
            let tokEmb = model.model.embedTokens(MLXArray([Int32(token)]).reshaped([1, 1]))
            hidden = model.model(inputsEmbeds: tokEmb, caches: caches)
            logits = model.logitsForLast(hidden)
            token = argMax(logits, axis: -1).item(Int.self)
        }

        if ProcessInfo.processInfo.environment["ASR_DEBUG"] != nil {
            print("raw ids: \(generated)")
            print("raw decode: \(tokenizer.decode(generated, skipSpecial: false))")
        }
        var text = tokenizer.decode(generated, skipSpecial: true)
        // strip auto-detected language prefix: "language X<asr_text>..."
        if let r = text.range(of: "<asr_text>"), text.hasPrefix("language ") {
            text = String(text[r.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if verbose {
            let total = Date().timeIntervalSince(t0)
            let genTime = Date().timeIntervalSince(tPrefill)
            let tps = genTime > 0 ? Double(generated.count) / genTime : 0
            print("generated \(generated.count) tokens in \(String(format: "%.1f", total))s (\(String(format: "%.1f", tps)) tok/s)")
        }
        return text
    }
}
