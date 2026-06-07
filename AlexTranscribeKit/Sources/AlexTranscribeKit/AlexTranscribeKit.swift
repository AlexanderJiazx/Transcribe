import Foundation

/// Public entry point for transcribing audio with `Qwen3-ASR-1.7B-8bit`, in pure Swift on MLX.
///
/// Create one instance per model directory (loading weights is the expensive step), then call
/// ``transcribe(audioURL:maxTokens:verbose:)`` as many times as needed.
///
/// ```swift
/// let asr = try AlexTranscriber(modelDirectory: modelDir)
/// let text = try asr.transcribe(audioURL: audioURL)
/// ```
public final class AlexTranscriber {
    private let transcriber: Transcriber

    /// Load the model from a directory containing `config.json`, `model.safetensors`,
    /// `vocab.json`, `merges.txt`, and `tokenizer_config.json`.
    public init(modelDirectory: URL) throws {
        let config = try ModelConfig.load(from: modelDirectory.appendingPathComponent("config.json"))
        let tokenizer = try BPETokenizer(modelDir: modelDirectory)
        let model = Qwen3ASRModel(config)
        try model.loadWeights(safetensors: modelDirectory.appendingPathComponent("model.safetensors"))
        transcriber = Transcriber(model: model, tokenizer: tokenizer)
    }

    /// Load the model from a folder bundled inside an app (the default).
    ///
    /// The model directory must be added to the app target as a *folder reference* so its
    /// files land under `…/Resources/<modelSubdirectory>/`. From a SwiftUI app you can
    /// simply call `try AlexTranscriber()`.
    /// - Parameters:
    ///   - bundle: the bundle to search (defaults to the running app's main bundle).
    ///   - modelSubdirectory: the bundled folder name (defaults to `Qwen3-ASR-1.7B-8bit`).
    public convenience init(
        bundle: Bundle = .main,
        modelSubdirectory: String = "Qwen3-ASR-1.7B-8bit"
    ) throws {
        guard let url = bundle.url(forResource: modelSubdirectory, withExtension: nil) else {
            throw TranscriberError.modelNotFoundInBundle(modelSubdirectory)
        }
        try self.init(modelDirectory: url)
    }

    /// Transcribe an audio file (wav/mp3/m4a/…). Language is auto-detected.
    /// - Parameters:
    ///   - audioURL: the audio file to transcribe.
    ///   - maxTokens: cap on generated tokens.
    ///   - verbose: when true, prints progress to stdout (off by default).
    /// - Returns: the transcribed text.
    public func transcribe(audioURL: URL, maxTokens: Int = 4096, verbose: Bool = false) throws -> String {
        try transcriber.transcribe(audioURL: audioURL, maxTokens: maxTokens, verbose: verbose)
    }

    /// Transcribe encoded audio bytes held in memory (wav/mp3/m4a/…) — no file needed.
    ///
    /// PCM WAV is decoded entirely in memory; other formats are briefly spilled to a temp
    /// file because AVFoundation's decoders require one.
    public func transcribe(audioData: Data, maxTokens: Int = 4096, verbose: Bool = false) throws -> String {
        let samples = try loadAudio16kMono(data: audioData)
        return try transcriber.transcribe(samples16k: samples, maxTokens: maxTokens, verbose: verbose)
    }

    /// Transcribe raw mono PCM samples held in memory. Resampled to 16 kHz if needed.
    /// - Parameter sampleRate: the sample rate of `samples` (defaults to 16 kHz).
    public func transcribe(
        samples: [Float],
        sampleRate: Double = 16000,
        maxTokens: Int = 4096,
        verbose: Bool = false
    ) throws -> String {
        let s = samples16kMono(samples, sampleRate: sampleRate)
        return try transcriber.transcribe(samples16k: s, maxTokens: maxTokens, verbose: verbose)
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case modelNotFoundInBundle(String)

    public var description: String {
        switch self {
        case .modelNotFoundInBundle(let name):
            return "Model folder '\(name)' was not found in the bundle. Add it to the app target as a folder reference."
        }
    }
}

/// One-shot convenience: load the model and transcribe a single file.
/// Prefer ``AlexTranscriber`` when transcribing more than once (avoids reloading weights).
public func transcribe(audioURL: URL, modelDirectory: URL) throws -> String {
    try AlexTranscriber(modelDirectory: modelDirectory).transcribe(audioURL: audioURL)
}
