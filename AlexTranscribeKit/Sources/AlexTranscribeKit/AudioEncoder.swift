import Foundation
import MLX
import MLXNN
import MLXFast

/// Conv output length of the audio frontend (matches Python _get_feat_extract_output_lengths).
///
/// The Python reference uses floor division (`-1 // 2 == -1`); Swift's `/` truncates toward
/// zero (`-1 / 2 == 0`). When `inputLen` is a multiple of 100 the truncating version returns
/// one too many, which made `featExtractOutputLength(100·k)` come out as `13·k + 1` instead of
/// `13·k`. Downstream that desynced the block-attention mask from the encoder's actual frame
/// count, indexing one row past the end of `maskFlat` and crashing with "Index out of range"
/// whenever the mel-frame count landed on a multiple of 100. Use floor division to match Python.
func featExtractOutputLength(_ inputLen: Int) -> Int {
    func fdiv(_ a: Int, _ b: Int) -> Int {        // Python floor division (//)
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }
    let leave = inputLen % 100
    let featLen = fdiv(leave - 1, 2) + 1
    return fdiv(fdiv(featLen - 1, 2) + 1 - 1, 2) + 1 + (inputLen / 100) * 13
}

private func sinusoidalPositionEmbedding(length: Int, channels: Int) -> MLXArray {
    let half = channels / 2
    let logInc = log(10000.0) / Double(half - 1)
    var inv = [Float](repeating: 0, count: half)
    for i in 0..<half { inv[i] = Float(exp(-logInc * Double(i))) }
    let invT = MLXArray(inv)                                   // (half,)
    let pos = MLXArray(Array(0..<length).map { Float($0) })    // (length,)
    let scaled = pos.reshaped([length, 1]) * invT.reshaped([1, half])  // (length, half)
    return concatenated([MLX.sin(scaled), MLX.cos(scaled)], axis: 1)   // (length, channels)
}


final class AudioAttention: Module {
    let numHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ cfg: AudioEncoderConfig) {
        let d_model = cfg.d_model
        numHeads = cfg.encoderAttentionHeads
        headDim = d_model / numHeads
        scale = pow(Float(headDim), -0.5)
        _qProj.wrappedValue = Linear(d_model, d_model, bias: true)
        _kProj.wrappedValue = Linear(d_model, d_model, bias: true)
        _vProj.wrappedValue = Linear(d_model, d_model, bias: true)
        _outProj.wrappedValue = Linear(d_model, d_model, bias: true)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let q = qProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        let k = kProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped([b, l, numHeads, headDim]).transposed(0, 2, 1, 3)
        let out = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask)
        return outProj(out.transposed(0, 2, 1, 3).reshaped([b, l, numHeads * headDim]))
    }
}

final class AudioEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: AudioAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(_ cfg: AudioEncoderConfig) {
        let dim = cfg.d_model
        _selfAttn.wrappedValue = AudioAttention(cfg)
        _selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: dim)
        _fc1.wrappedValue = Linear(dim, cfg.encoderFfnDim)
        _fc2.wrappedValue = Linear(cfg.encoderFfnDim, dim)
        _finalLayerNorm.wrappedValue = LayerNorm(dimensions: dim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        var h = x + selfAttn(selfAttnLayerNorm(x), mask: mask)
        h = h + fc2(gelu(fc1(finalLayerNorm(h))))
        return h
    }
}

final class AudioEncoder: Module {
    let cfg: AudioEncoderConfig

    @ModuleInfo(key: "conv2d1") var conv1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [AudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    init(_ cfg: AudioEncoderConfig) {
        self.cfg = cfg
        let dim = cfg.d_model
        let hidden = cfg.downsampleHiddenSize
        _conv1.wrappedValue = Conv2d(inputChannels: 1, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        _conv2.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        _conv3.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        let freqAfterConv = ((((cfg.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(hidden * freqAfterConv, dim, bias: false)
        _layers.wrappedValue = (0..<cfg.encoderLayers).map { _ in AudioEncoderLayer(cfg) }
        _lnPost.wrappedValue = LayerNorm(dimensions: dim)
        _proj1.wrappedValue = Linear(dim, dim)
        _proj2.wrappedValue = Linear(dim, cfg.outputDim)
        super.init()
    }

    /// Encode a single audio's mel features (128, T) -> (numAudioTokens, output_dim).
    func callAsFunction(_ inputFeatures: MLXArray) throws -> MLXArray {
        let featLen = inputFeatures.dim(1)  // T (single audio, fully valid)
        let chunkSize = cfg.nWindow * 2     // 100

        // split T into chunks of `chunkSize` (last may be shorter)
        let numChunks = Int(ceil(Double(featLen) / Double(chunkSize)))
        var chunkLens = [Int]()
        for j in 0..<numChunks {
            if j == numChunks - 1 {
                let rem = featLen % chunkSize
                chunkLens.append(rem == 0 ? chunkSize : rem)
            } else {
                chunkLens.append(chunkSize)
            }
        }
        let maxChunkLen = chunkLens.max()!

        // build padded chunks (numChunks, 128, maxChunkLen)
        var paddedChunks = [MLXArray]()
        var pos = 0
        for j in 0..<numChunks {
            let clen = chunkLens[j]
            var chunk = inputFeatures[0..., pos ..< (pos + clen)]  // (128, clen)
            if clen < maxChunkLen {
                chunk = padded(chunk, widths: [.init((0, 0)), .init((0, maxChunkLen - clen))])
            }
            paddedChunks.append(chunk)
            pos += clen
        }
        let paddedFeature = stacked(paddedChunks, axis: 0)  // (numChunks, 128, maxChunkLen)

        // per-chunk conv output lengths and full after-cnn length
        let chunkAfterCnn = chunkLens.map { featExtractOutputLength($0) }
        let maxLenAfterCnn = chunkAfterCnn.max()!
        let aftercnnLen = featExtractOutputLength(featLen)

        // conv frontend (NHWC: N=numChunks, H=128 mel, W=time, C=1)
        var x = paddedFeature.reshaped([numChunks, cfg.numMelBins, maxChunkLen, 1])
        x = gelu(conv1(x))
        x = gelu(conv2(x))
        x = gelu(conv3(x))
        // x: (numChunks, freq=16, t_after, C=480)
        let b = x.dim(0), f = x.dim(1), t = x.dim(2), c = x.dim(3)
        x = x.transposed(0, 2, 3, 1).reshaped([b, t, c * f])  // (numChunks, t_after, 7680)
        x = convOut(x)                                        // (numChunks, t_after, dim)

        let posEmb = sinusoidalPositionEmbedding(length: x.dim(1), channels: cfg.d_model)
        x = x + posEmb.reshaped([1, x.dim(1), cfg.d_model])

        // gather valid frames per chunk and concatenate over time.
        // Clamp to the conv output `t` so a stale length can never overrun the tensor (MLX
        // would clamp silently anyway; being explicit keeps the frame count well-defined).
        var hiddenList = [MLXArray]()
        for j in 0..<numChunks {
            hiddenList.append(x[j, 0 ..< Swift.min(chunkAfterCnn[j], t), 0...])
        }
        var hidden = concatenated(hiddenList, axis: 0)  // (seq, dim)
        let seqLen = hidden.dim(0)

        // block attention windows
        let windowAfterCnn = maxLenAfterCnn * (cfg.nWindowInfer / (cfg.nWindow * 2))
        var cuChunkLens = [0]
        let numFullWindows = aftercnnLen / windowAfterCnn
        for _ in 0..<numFullWindows { cuChunkLens.append(windowAfterCnn) }
        let remainder = aftercnnLen % windowAfterCnn
        if remainder != 0 { cuChunkLens.append(remainder) }
        var cuSeqlens = [Int]()
        var acc = 0
        for v in cuChunkLens { acc += v; cuSeqlens.append(acc) }

        // The window bounds come from `aftercnnLen`; the mask is sized from the encoder's
        // actual `seqLen`. These must agree — if they ever don't, throw instead of letting
        // the fill loop below index past the end of `maskFlat` (a fatal Swift trap).
        guard (cuSeqlens.last ?? 0) <= seqLen else {
            throw AudioError.featureLengthMismatch(
                "mask windows reach \(cuSeqlens.last ?? 0) but encoder produced \(seqLen) frames")
        }

        // additive block mask (seqLen, seqLen)
        var maskFlat = [Float](repeating: -1e9, count: seqLen * seqLen)
        for i in 0..<(cuSeqlens.count - 1) {
            let start = cuSeqlens[i], end = cuSeqlens[i + 1]
            for r in start..<end {
                for col in start..<end {
                    maskFlat[r * seqLen + col] = 0.0
                }
            }
        }
        let mask = MLXArray(maskFlat, [1, 1, seqLen, seqLen])

        hidden = hidden.reshaped([1, seqLen, cfg.d_model])
        for layer in layers {
            hidden = layer(hidden, mask: mask)
        }
        hidden = hidden.reshaped([seqLen, cfg.d_model])
        hidden = lnPost(hidden)
        hidden = gelu(proj1(hidden))
        hidden = proj2(hidden)
        return hidden  // (seq == numAudioTokens, output_dim)
    }
}
