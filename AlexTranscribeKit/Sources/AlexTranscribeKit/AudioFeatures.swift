import Foundation
import AVFoundation
import MLX
import MLXFFT

enum AudioError: Error, CustomStringConvertible {
    case decodeFailed(String)
    /// Audio is too short for the mel front-end (needs at least `nFFT/2 + 1` samples at 16 kHz).
    case audioTooShort(sampleCount: Int, minimum: Int)
    /// The audio encoder produced a frame count that disagrees with the predicted length.
    /// Thrown instead of trapping on an out-of-bounds index, so the caller can recover.
    case featureLengthMismatch(String)

    var description: String {
        switch self {
        case .decodeFailed(let m): return "Audio decode failed: \(m)"
        case .audioTooShort(let n, let min):
            return "Audio too short to transcribe: \(n) samples (need at least \(min))"
        case .featureLengthMismatch(let m): return "Audio feature length mismatch: \(m)"
        }
    }
}

/// Load audio as 16 kHz mono Float samples.
///
/// Detects PCM WAV by content (the sample file is a WAV with a `.mp3` extension,
/// which Core Audio refuses to open). Falls back to AVAudioFile for real
/// compressed formats.
///
/// Public so tooling/tests can decode exactly what the transcriber will see.
public func loadAudio16kMono(url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    if isWAV(data) {
        return try decodeWAV16kMono(data)
    }
    return try loadViaAVFoundation(url: url)
}

/// Decode encoded audio bytes held in memory (no disk round-trip) to 16 kHz mono.
///
/// PCM WAV is parsed directly in memory. For genuinely compressed formats (mp3/m4a/…),
/// AVFoundation requires a file, so the bytes are spilled to a temp file that is removed
/// immediately afterwards.
func loadAudio16kMono(data: Data) throws -> [Float] {
    if isWAV(data) {
        return try decodeWAV16kMono(data)
    }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".audio")
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    return try loadViaAVFoundation(url: tmp)
}

/// Resample raw mono PCM samples to 16 kHz (no-op when already 16 kHz).
func samples16kMono(_ samples: [Float], sampleRate: Double) -> [Float] {
    sampleRate == 16000 ? samples : resample(samples, from: sampleRate, to: 16000)
}

private func isWAV(_ data: Data) -> Bool {
    data.count > 12 &&
    data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&   // "RIFF"
    data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45    // "WAVE"
}

private func decodeWAV16kMono(_ data: Data) throws -> [Float] {
    let (samples, srcRate) = try parseWAV(data)
    return samples16kMono(samples, sampleRate: srcRate)
}

private func readU32LE(_ d: Data, _ o: Int) -> Int {
    Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24)
}
private func readU16LE(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }

/// Parse a PCM WAV (16-bit int or 32-bit float), returning mono float samples + sample rate.
func parseWAV(_ d: Data) throws -> ([Float], Double) {
    var offset = 12
    var numChannels = 1, sampleRate = 16000, bitsPerSample = 16, audioFormat = 1
    var dataStart = -1, dataLen = 0
    while offset + 8 <= d.count {
        let id = String(bytes: d[offset..<offset + 4], encoding: .ascii) ?? ""
        let size = readU32LE(d, offset + 4)
        let body = offset + 8
        if id == "fmt " {
            audioFormat = readU16LE(d, body)
            numChannels = readU16LE(d, body + 2)
            sampleRate = readU32LE(d, body + 4)
            bitsPerSample = readU16LE(d, body + 14)
        } else if id == "data" {
            dataStart = body
            dataLen = min(size, d.count - body)
            break
        }
        offset = body + size + (size & 1)  // chunks are word-aligned
    }
    guard dataStart >= 0 else { throw AudioError.decodeFailed("WAV: no data chunk") }

    let bytesPerSample = bitsPerSample / 8
    let frameCount = dataLen / (bytesPerSample * numChannels)
    var out = [Float](repeating: 0, count: frameCount)
    d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let base = raw.baseAddress!.advanced(by: dataStart)
        for i in 0..<frameCount {
            var acc: Float = 0
            for c in 0..<numChannels {
                let p = base.advanced(by: (i * numChannels + c) * bytesPerSample)
                if audioFormat == 3 && bitsPerSample == 32 {
                    acc += p.loadUnaligned(as: Float.self)
                } else if bitsPerSample == 16 {
                    acc += Float(p.loadUnaligned(as: Int16.self)) / 32768.0
                } else if bitsPerSample == 32 {
                    acc += Float(p.loadUnaligned(as: Int32.self)) / 2147483648.0
                }
            }
            out[i] = acc / Float(numChannels)
        }
    }
    return (out, Double(sampleRate))
}

/// Resample mono float samples using AVAudioConverter.
func resample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
    guard let srcFormat = AVAudioFormat(standardFormatWithSampleRate: srcRate, channels: 1),
          let dstFormat = AVAudioFormat(standardFormatWithSampleRate: dstRate, channels: 1),
          let converter = AVAudioConverter(from: srcFormat, to: dstFormat),
          let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { return samples }

    inBuf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    let outCap = AVAudioFrameCount(Double(samples.count) * dstRate / srcRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCap) else { return samples }

    var fed = false
    var err: NSError?
    _ = converter.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return inBuf
    }
    let n = Int(outBuf.frameLength)
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
}

private func loadViaAVFoundation(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let srcFormat = file.processingFormat

    guard let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    ) else { throw AudioError.decodeFailed("cannot create 16k format") }

    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
        throw AudioError.decodeFailed("cannot create converter")
    }

    let srcFrameCount = AVAudioFrameCount(file.length)
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrameCount) else {
        throw AudioError.decodeFailed("cannot alloc input buffer")
    }
    try file.read(into: inBuf)

    // Estimate output capacity generously.
    let ratio = 16000.0 / srcFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(srcFrameCount) * ratio) + 16000
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else {
        throw AudioError.decodeFailed("cannot alloc output buffer")
    }

    var fed = false
    var convErr: NSError?
    let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
        if fed {
            outStatus.pointee = .endOfStream
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return inBuf
    }
    if status == .error { throw AudioError.decodeFailed(convErr?.localizedDescription ?? "convert error") }

    let n = Int(outBuf.frameLength)
    let ptr = outBuf.floatChannelData![0]
    return Array(UnsafeBufferPointer(start: ptr, count: n))
}

/// Whisper-style 128-bin log-mel feature extractor (matches transformers WhisperFeatureExtractor).
struct WhisperMel {
    let nFFT = 400
    let hop = 160
    let nMels = 128
    let sampleRate = 16000

    let melMatrix: MLXArray   // (201, 128)
    let window: MLXArray      // (400,)

    init() {
        let numFreq = nFFT / 2 + 1  // 201
        let mat = WhisperMel.melFilterBank(numFreqBins: numFreq, numMel: nMels,
                                           minFreq: 0, maxFreq: 8000, sampleRate: sampleRate)
        melMatrix = MLXArray(mat, [numFreq, nMels])

        // periodic hann: 0.5 - 0.5*cos(2*pi*n/nFFT), n = 0..nFFT-1
        var w = [Float](repeating: 0, count: nFFT)
        for n in 0..<nFFT {
            w[n] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(nFFT)))
        }
        window = MLXArray(w)
    }

    // MARK: mel filter bank (slaney scale + slaney norm)

    static func hzToMelSlaney(_ f: Double) -> Double {
        let minLogHz = 1000.0, minLogMel = 15.0
        let logstep = 27.0 / log(6.4)
        if f >= minLogHz { return minLogMel + log(f / minLogHz) * logstep }
        return 3.0 * f / 200.0
    }
    static func melToHzSlaney(_ m: Double) -> Double {
        let minLogHz = 1000.0, minLogMel = 15.0
        let logstep = log(6.4) / 27.0
        if m >= minLogMel { return minLogHz * exp(logstep * (m - minLogMel)) }
        return 200.0 * m / 3.0
    }

    static func melFilterBank(numFreqBins: Int, numMel: Int, minFreq: Double, maxFreq: Double,
                              sampleRate: Int) -> [Float] {
        // fft bin frequencies: linspace(0, sr/2, numFreqBins)
        let nyquist = Double(sampleRate / 2)
        var fftFreqs = [Double](repeating: 0, count: numFreqBins)
        for i in 0..<numFreqBins {
            fftFreqs[i] = nyquist * Double(i) / Double(numFreqBins - 1)
        }
        // filter center frequencies (in Hz) spaced evenly in mel
        let melMin = hzToMelSlaney(minFreq)
        let melMax = hzToMelSlaney(maxFreq)
        let count = numMel + 2
        var filterFreqs = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let mel = melMin + (melMax - melMin) * Double(i) / Double(count - 1)
            filterFreqs[i] = melToHzSlaney(mel)
        }
        var diff = [Double](repeating: 0, count: count - 1)
        for i in 0..<(count - 1) { diff[i] = filterFreqs[i + 1] - filterFreqs[i] }

        // (numFreqBins, numMel)
        var out = [Float](repeating: 0, count: numFreqBins * numMel)
        for f in 0..<numFreqBins {
            for m in 0..<numMel {
                // slopes for filter m use filterFreqs[m], [m+1], [m+2]
                let down = -(filterFreqs[m] - fftFreqs[f]) / diff[m]
                let up = (filterFreqs[m + 2] - fftFreqs[f]) / diff[m + 1]
                var v = Swift.max(0.0, Swift.min(down, up))
                // slaney normalization
                let enorm = 2.0 / (filterFreqs[m + 2] - filterFreqs[m])
                v *= enorm
                out[f * numMel + m] = Float(v)
            }
        }
        return out
    }

    /// Compute log-mel features. Returns (features (128, T), numFrames T).
    ///
    /// Throws `AudioError.audioTooShort` when `audio` has fewer than `nFFT/2 + 1` samples
    /// (201 at 16 kHz / ≈ 12.5 ms). This replaces what would otherwise be a fatal
    /// "Index out of range" crash in the reflect-pad, letting the caller recover.
    func features(from audio: [Float]) throws -> (MLXArray, Int) {
        let pad = nFFT / 2  // 200, reflect
        let minSamples = pad + 1  // reflect-pad below reads audio[pad], so count must be ≥ pad+1
        guard audio.count >= minSamples else {
            throw AudioError.audioTooShort(sampleCount: audio.count, minimum: minSamples)
        }

        // reflect-pad in Swift (numpy 'reflect' semantics, no edge repeat)
        var padded = [Float]()
        padded.reserveCapacity(audio.count + 2 * pad)
        for i in 0..<pad { padded.append(audio[pad - i]) }       // audio[200..1] reversed -> audio[1..200] reversed
        padded.append(contentsOf: audio)
        let n = audio.count
        for i in 0..<pad { padded.append(audio[n - 2 - i]) }     // audio[-2..-201] reversed

        let paddedLen = padded.count
        let numFrames = 1 + (paddedLen - nFFT) / hop

        let paddedArr = MLXArray(padded)  // (paddedLen,)
        // frames via strided view: (numFrames, nFFT), strides (hop, 1)
        let frames = asStrided(paddedArr, [numFrames, nFFT], strides: [hop, 1], offset: 0)

        let windowed = frames * window           // (numFrames, 400)
        let spec = rfft(windowed, axis: -1)      // (numFrames, 201) complex
        let power = MLX.abs(spec) ** 2           // (numFrames, 201)

        var melSpec = power.matmul(melMatrix)    // (numFrames, 128)
        melSpec = MLX.maximum(melSpec, MLXArray(Float(1e-10)))
        var logSpec = MLX.log10(melSpec)         // (numFrames, 128)

        // drop the last time frame
        logSpec = logSpec[0 ..< (numFrames - 1), 0...]

        let maxv = logSpec.max()
        logSpec = MLX.maximum(logSpec, maxv - 8.0)
        logSpec = (logSpec + 4.0) / 4.0

        // model expects (mel_bins, T)
        let feats = logSpec.transposed(1, 0)     // (128, T)
        feats.eval()
        return (feats, numFrames - 1)
    }
}
