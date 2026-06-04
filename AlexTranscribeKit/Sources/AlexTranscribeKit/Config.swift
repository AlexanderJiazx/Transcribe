import Foundation

/// Audio encoder configuration (qwen3_asr_audio_encoder).
struct AudioEncoderConfig {
    var numMelBins = 128
    var encoderLayers = 24
    var encoderAttentionHeads = 16
    var encoderFfnDim = 4096
    var d_model = 1024
    var scaleEmbedding = false
    var maxSourcePositions = 1500
    var nWindow = 50
    var outputDim = 2048
    var nWindowInfer = 800
    var convChunksize = 500
    var downsampleHiddenSize = 480
}

/// Text decoder configuration (Qwen3-based).
struct TextConfig {
    var vocabSize = 151936
    var hiddenSize = 2048
    var intermediateSize = 6144
    var numHiddenLayers = 28
    var numAttentionHeads = 16
    var numKeyValueHeads = 8
    var headDim = 128
    var rmsNormEps: Float = 1e-6
    var tieWordEmbeddings = true
    var ropeTheta: Float = 1_000_000
}

/// Top-level model configuration.
struct ModelConfig {
    var audio = AudioEncoderConfig()
    var text = TextConfig()
    var audioTokenId = 151676
    var audioStartTokenId = 151669
    var audioEndTokenId = 151670
    var supportLanguages: [String] = []
    var quantGroupSize = 64
    var quantBits = 8

    static func load(from path: URL) throws -> ModelConfig {
        let data = try Data(contentsOf: path)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var cfg = ModelConfig()

        cfg.supportLanguages = (json["support_languages"] as? [String]) ?? []
        if let q = json["quantization"] as? [String: Any] {
            cfg.quantGroupSize = (q["group_size"] as? Int) ?? 64
            cfg.quantBits = (q["bits"] as? Int) ?? 8
        }

        let thinker = (json["thinker_config"] as? [String: Any]) ?? [:]
        cfg.audioTokenId = (thinker["audio_token_id"] as? Int) ?? cfg.audioTokenId
        cfg.audioStartTokenId = (thinker["audio_start_token_id"] as? Int) ?? cfg.audioStartTokenId
        cfg.audioEndTokenId = (thinker["audio_end_token_id"] as? Int) ?? cfg.audioEndTokenId

        if let ac = thinker["audio_config"] as? [String: Any] {
            var a = AudioEncoderConfig()
            a.numMelBins = (ac["num_mel_bins"] as? Int) ?? a.numMelBins
            a.encoderLayers = (ac["encoder_layers"] as? Int) ?? a.encoderLayers
            a.encoderAttentionHeads = (ac["encoder_attention_heads"] as? Int) ?? a.encoderAttentionHeads
            a.encoderFfnDim = (ac["encoder_ffn_dim"] as? Int) ?? a.encoderFfnDim
            a.d_model = (ac["d_model"] as? Int) ?? a.d_model
            a.maxSourcePositions = (ac["max_source_positions"] as? Int) ?? a.maxSourcePositions
            a.nWindow = (ac["n_window"] as? Int) ?? a.nWindow
            a.outputDim = (ac["output_dim"] as? Int) ?? a.outputDim
            a.nWindowInfer = (ac["n_window_infer"] as? Int) ?? a.nWindowInfer
            a.convChunksize = (ac["conv_chunksize"] as? Int) ?? a.convChunksize
            a.downsampleHiddenSize = (ac["downsample_hidden_size"] as? Int) ?? a.downsampleHiddenSize
            cfg.audio = a
        }

        if let tc = thinker["text_config"] as? [String: Any] {
            var t = TextConfig()
            t.vocabSize = (tc["vocab_size"] as? Int) ?? t.vocabSize
            t.hiddenSize = (tc["hidden_size"] as? Int) ?? t.hiddenSize
            t.intermediateSize = (tc["intermediate_size"] as? Int) ?? t.intermediateSize
            t.numHiddenLayers = (tc["num_hidden_layers"] as? Int) ?? t.numHiddenLayers
            t.numAttentionHeads = (tc["num_attention_heads"] as? Int) ?? t.numAttentionHeads
            t.numKeyValueHeads = (tc["num_key_value_heads"] as? Int) ?? t.numKeyValueHeads
            t.headDim = (tc["head_dim"] as? Int) ?? t.headDim
            if let eps = tc["rms_norm_eps"] as? Double { t.rmsNormEps = Float(eps) }
            t.tieWordEmbeddings = (tc["tie_word_embeddings"] as? Bool) ?? t.tieWordEmbeddings
            if let theta = tc["rope_theta"] as? Double { t.ropeTheta = Float(theta) }
            cfg.text = t
        }
        return cfg
    }
}
