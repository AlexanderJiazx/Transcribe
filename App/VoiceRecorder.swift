import Foundation
import AVFoundation

/// Captures microphone audio into memory as raw mono PCM samples.
///
/// Nothing is written to disk — the accumulated `[Float]` samples are handed straight to
/// `AlexTranscriber.transcribe(samples:sampleRate:)`, which resamples to 16 kHz as needed.
///
/// The tap callback runs on a realtime audio thread, so the sample buffer is guarded by a lock.
final class VoiceRecorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var captureSampleRate: Double = 16000
    private(set) var isRecording = false

    /// Current microphone authorization. `.notDetermined` is the only state that can still prompt.
    var permissionStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Ask for microphone access. Only shows the system prompt when status is `.notDetermined`;
    /// once denied, macOS will never re-prompt — the user must re-enable it in System Settings.
    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Begin capturing. Discards any previously captured audio.
    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)   // hardware rate, e.g. 44.1/48 kHz
        captureSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)

            // Downmix to mono by averaging channels.
            var chunk = [Float](repeating: 0, count: frames)
            for c in 0..<channelCount {
                let p = channels[c]
                for i in 0..<frames { chunk[i] += p[i] }
            }
            if channelCount > 1 {
                let inv = 1 / Float(channelCount)
                for i in 0..<frames { chunk[i] *= inv }
            }

            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop capturing and return what was recorded, with its sample rate.
    @discardableResult
    func stop() -> (samples: [Float], sampleRate: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock(); let captured = samples; lock.unlock()
        return (captured, captureSampleRate)
    }
}
