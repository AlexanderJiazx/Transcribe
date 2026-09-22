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

    /// Test-feed state: when set, `stop()` skips engine teardown (no mic was started).
    private var feedTimer: DispatchSourceTimer?

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

    /// Read the capture so far without stopping — the streaming tick loop snapshots the
    /// buffer this way for each intermediate transcription pass.
    func snapshot() -> (samples: [Float], sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        return (samples, captureSampleRate)
    }

    /// Begin capturing. Discards any previously captured audio.
    func start() throws {
        print("[rec] start() entered")
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        // AVAudioEngine raises ObjC NSExceptions (not Swift errors) when there is no
        // usable input device — e.g. installTap's "format mismatch" on the phantom
        // format a device-less machine reports. An NSException unwinds uncatchably
        // through Swift code and, on the main runloop, is swallowed by the event
        // handler — leaving the recording overlay stuck open with no capture. Guard
        // before touching the engine.
        // Discovery session covers modern devices; devices(for:) is the complete
        // fallback so unusual input devices (Bluetooth, virtual drivers) aren't
        // falsely reported as absent.
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        let inputs = discovered.isEmpty ? AVCaptureDevice.devices(for: .audio) : discovered
        guard !inputs.isEmpty else {
            print("[rec] no audio input devices — refusing to start engine")
            throw NSError(domain: "VoiceRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no audio input device"])
        }

        let input = engine.inputNode
        print("[rec] got inputNode")
        let format = input.outputFormat(forBus: 0)   // hardware rate, e.g. 44.1/48 kHz
        print("[rec] input format \(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "invalid input format \(format)"])
        }
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

        print("[rec] tap installed")
        engine.prepare()
        print("[rec] prepared")
        try engine.start()
        print("[rec] engine started running=\(engine.isRunning)")
        isRecording = true
    }

    /// Testing seam: feed pre-captured samples into the buffer at real-time pace instead
    /// of touching the microphone, so the streaming transcription path can be exercised
    /// on machines with no audio input device.
    func start(testFeed feed: [Float], sampleRate: Double) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        captureSampleRate = sampleRate
        isRecording = true
        lock.unlock()

        let chunk = max(1, Int(sampleRate * 0.1))   // drip 100 ms of audio per tick
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.isRecording, offset < feed.count else {
                self.lock.unlock()
                return
            }
            let end = min(offset + chunk, feed.count)
            self.samples.append(contentsOf: feed[offset..<end])
            offset = end
            self.lock.unlock()
        }
        timer.resume()
        feedTimer = timer
    }

    /// Stop capturing and return what was recorded, with its sample rate.
    @discardableResult
    func stop() -> (samples: [Float], sampleRate: Double) {
        feedTimer?.cancel()
        feedTimer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRecording = false
        lock.lock(); let captured = samples; lock.unlock()
        return (captured, captureSampleRate)
    }
}
