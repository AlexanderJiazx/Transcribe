import Foundation
import MLX
import MLXNN
import MLXFast

/// Simple key/value cache for autoregressive generation.
final class KVCache {
    var keys: MLXArray?
    var values: MLXArray?
    var offset = 0

    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        if let ek = keys, let ev = values {
            keys = concatenated([ek, k], axis: 2)
            values = concatenated([ev, v], axis: 2)
        } else {
            keys = k
            values = v
        }
        offset += k.dim(2)
        return (keys!, values!)
    }
}

private func causalMask(_ n: Int, offset: Int, dtype: DType) -> MLXArray {
    let total = offset + n
    let rinds = MLXArray(Array(0..<total).map { Int32($0) })
    let lstart = offset == 0 ? 0 : offset
    let linds = MLXArray(Array(lstart..<(lstart + n)).map { Int32($0) })
    let m = MLX.less(linds.reshaped([n, 1]), rinds.reshaped([1, total]))  // bool (n, total)
    return m.asType(dtype) * MLXArray(Float(-1e9)).asType(dtype)
}

final class TextAttention: Module {
    let numHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ cfg: TextConfig) {
        numHeads = cfg.numAttentionHeads
        numKVHeads = cfg.numKeyValueHeads
        headDim = cfg.headDim
        scale = pow(Float(headDim), -0.5)
        _qProj.wrappedValue = Linear(cfg.hiddenSize, numHeads * headDim, bias: false)
        _kProj.wrappedValue = Linear(cfg.hiddenSize, numKVHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(cfg.hiddenSize, numKVHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(numHeads * headDim, cfg.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: cfg.rmsNormEps)
        rope = RoPE(dimensions: headDim, traditional: false, base: cfg.ropeTheta)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        var q = qProj(x).reshaped([b, l, numHeads, headDim])
        var k = kProj(x).reshaped([b, l, numKVHeads, headDim])
        var v = vProj(x).reshaped([b, l, numKVHeads, headDim])

        q = qNorm(q).transposed(0, 2, 1, 3)
        k = kNorm(k).transposed(0, 2, 1, 3)
        v = v.transposed(0, 2, 1, 3)

        let offset = cache.offset
        q = rope(q, offset: offset)
        k = rope(k, offset: offset)

        (k, v) = cache.update(k, v)

        let mask = causalMask(l, offset: offset, dtype: q.dtype)
        let out = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask)
        return oProj(out.transposed(0, 2, 1, 3).reshaped([b, l, numHeads * headDim]))
    }
}

final class TextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ cfg: TextConfig) {
        _gateProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(cfg.intermediateSize, cfg.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

final class TextDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: TextAttention
    @ModuleInfo(key: "mlp") var mlp: TextMLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ cfg: TextConfig) {
        _selfAttn.wrappedValue = TextAttention(cfg)
        _mlp.wrappedValue = TextMLP(cfg)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, cache: KVCache) -> MLXArray {
        var h = x + selfAttn(inputLayerNorm(x), cache: cache)
        h = h + mlp(postAttentionLayerNorm(h))
        return h
    }
}

final class TextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [TextDecoderLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ cfg: TextConfig) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: cfg.vocabSize, dimensions: cfg.hiddenSize)
        _layers.wrappedValue = (0..<cfg.numHiddenLayers).map { _ in TextDecoderLayer(cfg) }
        _norm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        super.init()
    }

    func callAsFunction(inputsEmbeds: MLXArray, caches: [KVCache]) -> MLXArray {
        var h = inputsEmbeds
        for (i, layer) in layers.enumerated() {
            h = layer(h, cache: caches[i])
        }
        return norm(h)
    }
}
