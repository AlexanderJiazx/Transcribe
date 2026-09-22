//
//  AppDelegate.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-04.
//

import AppKit
import Carbon.HIToolbox   // IsSecureEventInputEnabled
import AlexTranscribeKit
import AVFAudio
import SpriteKit
import MLX


enum WindowState {
    case expanded
    case hidden
}

struct ScreenInfo{
    var width: CGFloat
    var height: CGFloat
    var fringeWidth: CGFloat
}

// The tap watchdog's liveness probe: a flagsChanged event for an option-key
// release. It is inert in every app (a release of a modifier that was never
// pressed), so leaking it when the tap is dead is harmless. Delivery of the
// probe (or of any event at all) is what proves the tap is alive; events
// tagged via eventSourceUserData are NOT delivered to our tap — observed in
// testing — so the probe must remain an ordinary untagged event.
private let tapProbeKeyCode: Int64 = 58  // left option

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var windowState: WindowState = .hidden
    
    //screen info
    var screenInfo: ScreenInfo = ScreenInfo(width: 0,
                                           height: 0,
                                           fringeWidth: 0)
    
    private let recorder = VoiceRecorder()
    
    private var transcriber: AlexTranscriber?
    
    private let transcribeQueue = DispatchQueue(label: "transcribe", qos: .userInitiated)  // ← add

    // Live-transcription state. While recording, a loop on transcribeQueue repeatedly
    // re-transcribes the growing capture; each pass' partials land in the focused text
    // field via the Accessibility API (LiveTextInserter), so the user sees words appear
    // during recording, not after it.
    private let inserter = LiveTextInserter()
    private var sessionSamples: [Float] = []
    private var sessionSampleRate: Double = 16000
    private let streamLock = NSLock()
    private var streamingActive = false
    private var lastTickSampleCount = 0
    /// Bumped each startRecord (main thread). Partials carry their session id so stale
    /// emissions queued on main from a previous session are dropped, never written.
    private var sessionID = 0
    /// Re-run transcription once this much *new* audio has accumulated since the last pass.
    private let tickAudioInterval: Double = 1.0   // seconds
    /// Don't start partial passes until this much audio exists (also clears the mel
    /// front-end's 201-sample minimum with margin).
    private let minTickAudio: Double = 0.7        // seconds
    /// Decode window cap for live ticks. Re-decoding the *whole* buffer every tick is
    /// O(n²) work that falls behind real speech; bounding the window keeps each tick's
    /// cost constant so partials arrive within a couple of seconds of being spoken.
    private let maxTickWindow: Double = 12.0      // seconds
    /// Words committed via local agreement never change again — only the tail is live.
    /// shownWords = committed prefix + revisable tail (what's on screen).
    /// committedEndSample tracks where committed audio ends; each tick's window start is
    /// anchored there or at the window cap — but correctness comes from aligning each new
    /// hypothesis onto shownWords by suffix overlap, not from the cursor estimate.
    private var shownWords: [String] = []
    private var committedCount = 0
    private var committedEndSample = 0
    private var prevTailNorm: [String] = []   // previous hyp's tail words, normalized
    private var prevBoundary = -1             // shown-index where the previous tail began
    private var alignMisses = 0
    /// Resyncs this session — a high count means the tick loop churned and
    /// committed text may carry artifacts, so the final pass must be authoritative.
    private var resyncCount = 0

    private var committedText: String {
        shownWords.prefix(committedCount).joined(separator: " ")
    }

    // Particle overlay shown inside the window during record + transcribe.
    private var skView: SKView?
    private var recordEmitter: SKEmitterNode?
    private var isTranscribing = false
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var tapWatchdog: Timer?
    // Heartbeat sent through the tap to detect silent death (the port can be
    // invalidated without ever delivering tapDisabledByTimeout — observed:
    // the tap stopped delivering all events with no disable notification).
    private var probePending = false
    // While another process holds secure event input (password fields,
    // Terminal's Secure Keyboard Entry, etc.), macOS hides all keyDown events
    // from our tap by design — the tap stays enabled and the port stays
    // valid, so rebuilds accomplish nothing and the missing presses cannot
    // be recovered. We detect it and stay quiet instead of thrashing.
    private var secureInputActive = false
    private var tapTestFired = false
    // Two consecutive missed probes are required before rebuilding — a single
    // dropped synthetic event must not churn the tap.
    private var probeLost = false

    private func initScreeninfo(){
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        
        screenInfo = ScreenInfo(width: fullFrame.width,
                                height: fullFrame.height,
                                fringeWidth: 184)
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two instances would both answer the hotkey and double-transcribe —
        // this fires for renamed copies too (Transcribe.app vs Transcribe-beta.app
        // share the bundle id). Bail before any taps/recordings are set up.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        if let existing = others.first {
            print("[app] instance already running (pid \(existing.processIdentifier)) — exiting")
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(__stdoutp, nil)   // unbuffer print() so redirected stdout shows logs live
        Task{
            await AVAudioApplication.requestRecordPermission()
            print("Asked audio permission")
        }
        
        initScreeninfo()
        
        //32 is the height of the fringe
        window = NSPanel(
            contentRect: NSRect(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height, width: screenInfo.fringeWidth, height: screenInfo.fringeWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        windowState = .hidden

        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.level = .screenSaver
        window.hasShadow = false

        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        (window as? NSPanel)?.becomesKeyOnlyIfNeeded = true

        // Move the panel into a dedicated, always-shown SkyLight space so it
        // stays fixed (does not slide) during Space-switch animations. Must run
        // after makeKeyAndOrderFront, when windowNumber > 0.
        FixedOverlaySpace.shared.adopt(window)
        window.orderFrontRegardless()

        // Warm the ASR model at launch so the first dictation starts instantly.
        transcribeQueue.async { [weak self] in
            guard let self, self.transcriber == nil else { return }
            do {
                self.transcriber = try AlexTranscriber()
                print("[record] model loaded")
            } catch {
                print("[record] model load failed: \(error)")
            }
        }

        keyPressInterception()
        /*
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
              guard let self else { return }
              self.moveWindow(to: NSPoint(x: (width-RectangleWidth)/2, y: height-windowHeight))
          }
         */

        let contentView = window.contentView!
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }

    private func startRecord(){
        //Start recording
        guard !recorder.isRecording else { return }

        //Load the model
        if transcriber == nil {
                transcribeQueue.async { [weak self] in
                    guard let self, self.transcriber == nil else { return }
                    do {
                        self.transcriber = try AlexTranscriber()
                        print("[record] model loaded")
                    } catch {
                        print("[record] model load failed: \(error)")
                    }
                }
            }

        sessionID += 1
        inserter.begin()    // new session: drop any tracked insertion state

        // requestPermission() prompts only when status is .notDetermined; it returns
        // false outright if access was previously denied or restricted.
        Task { @MainActor in
            // Testing seam: TRANSCRIBE_TEST_PCM=<path to raw Float32-LE 16 kHz PCM> feeds
            // that file at real-time pace instead of the microphone — exercises the whole
            // streaming path on machines without an audio input device.
            if let pcmPath = ProcessInfo.processInfo.environment["TRANSCRIBE_TEST_PCM"] {
                guard let feed = loadTestPCM(pcmPath) else {
                    print("[record] TRANSCRIBE_TEST_PCM set but couldn't read \(pcmPath)")
                    return
                }
                sessionSamples = []
                recorder.start(testFeed: feed, sampleRate: 16000)
                startStreaming()
                print("[record] test feed started (\(feed.count) samples)")
                return
            }

            guard await recorder.requestPermission() else {
                print("[record] microphone access denied — enable it in System Settings")
                return
            }
            do {
                sessionSamples = []             // discard any previous capture
                try recorder.start()
                startStreaming()
                print("[record] recording started")
            } catch {
                print("[record] couldn't start: \(error.localizedDescription)")
            }
        }
        
    }

    /// Raw little-endian Float32 mono PCM reader for the TRANSCRIBE_TEST_PCM test feed.
    private func loadTestPCM(_ path: String) -> [Float]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
            }
        }
        return out
    }

    // MARK: - Streaming ticks

    private func setStreamingActive(_ v: Bool) {
        streamLock.lock(); streamingActive = v; streamLock.unlock()
    }
    private func isStreamingActive() -> Bool {
        streamLock.lock(); defer { streamLock.unlock() }; return streamingActive
    }

    /// Kick off the partial-transcription loop on transcribeQueue. Enqueued *after* the
    /// model-load block from startRecord, so the model is warm before the first tick.
    private func startStreaming() {
        let session = sessionID
        streamLock.lock()
        streamingActive = true
        lastTickSampleCount = 0
        shownWords = []
        committedCount = 0
        committedEndSample = 0
        prevTailNorm = []
        prevBoundary = -1
        alignMisses = 0
        resyncCount = 0
        streamLock.unlock()
        transcribeQueue.async { [weak self] in self?.streamingLoop(session: session) }
    }

    /// Local-agreement streaming decode. Each tick re-decodes only the audio since the
    /// last committed word (bounded by `maxTickWindow`), then compares word-level with
    /// the previous hypothesis: the longest common prefix — minus a two-word safety
    /// margin — is committed forever; only the divergent tail stays live. Committed
    /// words are never re-decoded or rewritten, so visible text grows stably and per-tick
    /// cost stays constant instead of growing with the recording.
    /// Runs on transcribeQueue until endRecord clears `streamingActive`; an in-flight
    /// pass aborts early via `isCancelled` so the final pass can start promptly.
    private func streamingLoop(session: Int) {
        while isStreamingActive() {
            let (samples, rate) = recorder.snapshot()
            let spanCount = samples.count - committedEndSample
            if let t = transcriber,
               Double(spanCount) >= minTickAudio * rate,
               Double(samples.count - lastTickSampleCount) >= tickAudioInterval * rate {
                lastTickSampleCount = samples.count
                let maxN = Int(maxTickWindow * rate)
                // Back up ~0.8s into committed audio: the cut then lands on stable words
                // the decoder re-says, so the hypothesis's prefix anchors onto shown text
                // by overlap instead of starting mid-word (which yields unmatched garbage).
                let overlapBack = Int(0.8 * rate)
                let windowStart = max(max(committedEndSample - overlapBack, 0),
                                      samples.count - maxN)
                let span = Array(samples[windowStart..<samples.count])
                do {
                    let hyp = try t.transcribe(
                        samples: span, sampleRate: rate, verbose: false,
                        isCancelled: { [weak self] in !(self?.isStreamingActive() ?? false) })
                    applyLocalAgreement(hypothesis: hyp, spanCount: span.count,
                                        windowStart: windowStart, session: session)
                } catch {
                    print("[stream] tick failed: \(error.localizedDescription)")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    /// Overlap-anchored local agreement. `hypothesis` is the decode of the window
    /// starting ~0.8s inside committed audio — so its first words usually re-say the end
    /// of what's on screen. We find where the hypothesis's word prefix best matches a
    /// contiguous run of `shownWords` (anywhere, not just at the tail end):
    ///   - words before the match are older than the decode edge → committed for good;
    ///   - the matched words confirm what they cover;
    ///   - words after the match are new — committed only where they agree with the
    ///     previous hypothesis's aligned tail (2-of-2 vote), keeping ≥2 revisable.
    /// Committed text is never re-selected or rewritten — only the tail after it moves.
    /// Anchoring by content (not an audio cursor) makes window drift harmless: an
    /// over/under-advanced window just shifts the match position instead of duplicating
    /// or losing words. ≥3 consecutive non-matches hard-resync the tail only.
    private func applyLocalAgreement(hypothesis: String, spanCount: Int,
                                     windowStart: Int, session: Int) {
        let words = hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        let wn = words.map(normalizeWord)

        var k = 0, s = 0
        var resynced = false
        if shownWords.isEmpty {
            s = 0; k = 0                       // first decode: whole hyp is the tail
        } else {
            (k, s) = bestOverlap(wn, shownWords)
            // A usable anchor: ≥2 matched words whose match reaches into the tail
            // (a match entirely inside the committed region covers nothing new).
            if k < 2 || s + k < committedCount {
                alignMisses += 1
                if alignMisses >= 3 {
                    // Hard resync. The decode window may not reach back to where
                    // the uncommitted tail began — blanket-replacing the tail would
                    // drop shown words whose audio is outside the window. Anchor
                    // inside the tail first so those pre-window words survive.
                    print("[stream] alignment resync after \(alignMisses) misses")
                    alignMisses = 0
                    resynced = true
                    resyncCount += 1
                    (s, k) = resyncAnchor(wn, hypCount: words.count)
                } else {
                    return
                }
            }
        }
        alignMisses = 0

        // W index where the tail replacement begins: past the match, and never touching
        // the committed region (matched words overlapping committed text are dropped so
        // committed characters stay verbatim, even when only the normalized form agreed).
        let tailFrom = max(k, committedCount - s)
        // 2-of-2 vote on new tail words: W[tailFrom+i] sits at shown position
        // s+tailFrom+i; prevTailNorm[j] sat at prevBoundary+j → j = i + (s+tailFrom-prevBoundary).
        // Commit votes only count on a real anchor — after a resync the previous
        // tail alignment is meaningless, so nothing new gets committed that tick.
        var extra = 0
        if !resynced, prevBoundary >= 0 {
            let d = s + tailFrom - prevBoundary
            while tailFrom + extra < words.count - 2 {
                let j = extra + d
                guard j >= 0, j < prevTailNorm.count, prevTailNorm[j] == wn[tailFrom + extra] else { break }
                extra += 1
            }
        }

        shownWords = Array(shownWords.prefix(s + tailFrom)) + Array(words.dropFirst(tailFrom))
        committedCount = min(shownWords.count, max(committedCount, s + tailFrom + extra))
        committedEndSample = max(committedEndSample,
            windowStart + Int(Double(spanCount) * Double(tailFrom + extra) / Double(words.count)))
        prevBoundary = s + tailFrom
        prevTailNorm = Array(wn.dropFirst(tailFrom))
        print("[stream] \(committedCount)w committed / \(shownWords.count) shown (match \(k)@\(s), +\(extra))")

        let committed = shownWords.prefix(committedCount).joined(separator: " ")
        emitPartial(shownWords.joined(separator: " "),
                    keepPrefix: committed.utf16.count, session: session)
    }

    /// Final-pass reconciliation: the window re-decode covers the tail plus recent
    /// shown audio and is fresher than the ticks that produced that text — splice
    /// it in wholesale at its fuzzy anchor (the LATEST acceptable match, since the
    /// window covers the end of the recording), rewriting whatever the ticks left
    /// there — including recently committed words — instead of merely appending.
    private func applyFinalWindow(hypothesis hyp: String) -> String {
        let words = hyp.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty {
            // No speech in the covered audio — drop the stale revisable tail.
            if shownWords.count > committedCount {
                shownWords = Array(shownWords.prefix(committedCount))
            }
            return shownWords.joined(separator: " ")
        }
        if shownWords.isEmpty {
            shownWords = words
            committedCount = words.count
            return shownWords.joined(separator: " ")
        }
        let wn = words.map(normalizeWord)
        // Anchor anywhere in shown text, but never earlier than the span the
        // window's audio could have produced (≈ one shown word per decode word).
        // Anchoring inside the committed region is allowed — the window decode is
        // fresher than the tick that committed those words.
        let floor = max(0, shownWords.count - words.count - 6)
        let anchor = spliceAnchor(wn, hypCount: words.count, floor: floor)
        if anchor >= 0 {
            shownWords = Array(shownWords.prefix(anchor)) + words
        } else {
            // No anchor — same fallback as streaming resyncs: keep committed
            // verbatim, append the decode minus any duplicated overlap.
            let matched = committedSuffixOverlap(wn, hypCount: words.count)
            shownWords = Array(shownWords.prefix(committedCount)) + words.dropFirst(matched)
        }
        committedCount = shownWords.count
        return shownWords.joined(separator: " ")
    }

    /// Fuzzy anchor of the hypothesis prefix onto shown words at positions ≥ floor:
    /// the latest position where ≥75% of the first L (≤12) hypothesis words appear
    /// as an in-order subsequence of the shown words within a bounded lookahead.
    /// Subsequence (not fixed-offset) matching tolerates the window decode
    /// inserting or dropping a word relative to the live ticks — a shifted run
    /// would otherwise fail the fixed-offset diff test and double the text.
    /// "Latest" because the decode window covers the end of the recording — a
    /// repeated phrase can anchor in several places and the real one is last.
    private func spliceAnchor(_ wn: [String], hypCount: Int, floor: Int) -> Int {
        let cn = shownWords.map(normalizeWord)
        let L = min(12, hypCount)
        guard L >= 3 else { return -1 }
        var anchor = -1
        var s = max(0, floor)
        while s < cn.count {
            if cn[s] == wn[0] {
                var i = s, w = 0, matched = 0
                let bound = min(cn.count, s + L + 6)
                while w < L, i < bound {
                    if cn[i] == wn[w] { w += 1; matched += 1 }
                    i += 1
                }
                if matched * 4 >= L * 3 { anchor = s }
            }
            s += 1
        }
        return anchor
    }

    /// How many leading hypothesis words re-say the committed suffix — used to
    /// skip a duplicated overlap when no tail anchor exists (resync fallback).
    /// Subsequence match over a slightly wider shown span tolerates one side
    /// inserting a word relative to the other.
    private func committedSuffixOverlap(_ wn: [String], hypCount: Int) -> Int {
        let cn = shownWords.map(normalizeWord)
        var m = min(10, committedCount, hypCount - 1)
        while m >= 3 {
            var i = max(0, committedCount - m - 2), w = 0, matched = 0
            while w < m, i < committedCount {
                if cn[i] == wn[w] { w += 1; matched += 1 }
                i += 1
            }
            if matched * 4 >= m * 3 { return m }
            m -= 1
        }
        return 0
    }

    /// Where a resync's hypothesis lands, as (s, k) for the shared replacement
    /// `prefix(s + tailFrom) + words[tailFrom:]` with tailFrom = max(k, c - s).
    /// Anchors inside the uncommitted tail when possible so shown words whose
    /// audio predates the decode window survive; otherwise replaces from the
    /// committed boundary minus the duplicated overlap.
    private func resyncAnchor(_ wn: [String], hypCount: Int) -> (s: Int, k: Int) {
        let anchor = spliceAnchor(wn, hypCount: hypCount, floor: committedCount)
        if anchor >= 0 { return (anchor, 0) }
        let matched = committedSuffixOverlap(wn, hypCount: hypCount)
        return (committedCount - matched, matched)
    }

    /// Best contiguous alignment of the hypothesis prefix onto shown text:
    /// returns (match length k, start index s in shown). Prefers longest match,
    /// then the position closest to the tail (least disruption). Normalized compare.
    private func bestOverlap(_ wn: [String], _ shown: [String]) -> (k: Int, s: Int) {
        let cn = shown.map(normalizeWord)
        var best = (0, -1)
        for start in 0..<cn.count {
            var k = 0
            while start + k < cn.count, k < wn.count, cn[start + k] == wn[k] { k += 1 }
            if k > best.0 || (k == best.0 && start > best.1) { best = (k, start) }
        }
        return best
    }

    /// Lowercase + strip non-alphanumerics so "And," vs "and" doesn't stall agreement.
    private func normalizeWord(_ w: String) -> String {
        String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func utf16CommonPrefix(_ a: String, _ b: String) -> Int {
        var i = a.utf16.startIndex, j = b.utf16.startIndex, n = 0
        while i != a.utf16.endIndex, j != b.utf16.endIndex, a.utf16[i] == b.utf16[j] {
            i = a.utf16.index(after: i); j = b.utf16.index(after: j); n += 1
        }
        return n
    }

    /// Route a cleaned partial transcript into the focused field via the AX inserter.
    /// `keepPrefix` chars at the start are committed and left untouched.
    /// Serial-queue → main dispatch keeps emissions in order; the session check drops
    /// stragglers from an already-finished session.
    private func emitPartial(_ text: String, keepPrefix: Int = 0, session: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == session else { return }
            // A tick that was mid-decode when recording stopped can dispatch its partial
            // after the final `finish()` write — the stale text would overwrite it.
            guard self.isStreamingActive() else { return }
            self.inserter.update(text, keepPrefix: keepPrefix)
        }
    }

    private func endRecord(){
        //End recording: stop the tick loop first so the final pass isn't queued behind it.
        guard recorder.isRecording else { return }
        setStreamingActive(false)
        let (samples, sampleRate) = recorder.stop()

        // The mel front-end reflect-pads by 200 samples, so inputs shorter than that crash
        // with "Index out of range". Skip accidental ultra-short taps (also pointless to
        // transcribe). Leaving sessionSamples empty makes transcribe()'s guard reset the UI.
        let minDuration = 0.2  // seconds
        guard Double(samples.count) >= minDuration * sampleRate else {
            print("[record] too short (\(samples.count) samples) — skipping transcription")
            return
        }

        sessionSamples = samples
        sessionSampleRate = sampleRate
        print("[record] captured \(String(format: "%.1f", Double(samples.count) / sampleRate))s")
    }

    private func transcribe(){
        //Final pass over the full capture; partials still stream into the field as it
        //decodes, then the transcript lands on the clipboard (as before).
        guard !sessionSamples.isEmpty else {
            print("[transcribe] no audio to transcribe")
            finishTranscription()       // don't leave the window stuck expanded
            return
        }
        let samples = sessionSamples
        let rate = sessionSampleRate
        let session = sessionID
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.transcriber == nil {
                    self.transcriber = try AlexTranscriber()   // bundled model, loaded once
                }
                // A full re-decode of the whole capture made the post-stop wait
                // scale with dictation length (a ~3min recording sat decoding for
                // minutes). The stream already committed most words — decode only
                // the uncommitted tail (from committedEndSample, with the same
                // 0.8s overlap the ticks use) and reconcile it through the same
                // alignment; the final text is then the complete shown text.
                let text: String
                let tailCount = samples.count - self.committedEndSample
                if self.committedEndSample > 0, tailCount > 0, self.resyncCount < 3 {
                    // Decode the uncommitted tail plus up to ~12s of already-shown
                    // audio — the window re-decode is fresher than the incremental
                    // ticks that produced that text, so it can repair recent
                    // streaming artifacts instead of freezing them. Bounded cost:
                    // ~12s of audio worst case, vs the whole capture.
                    let overlapBack = Int(0.8 * rate)
                    let windowStart = max(0,
                        min(self.committedEndSample - overlapBack,
                            samples.count - Int(12 * rate)))
                    let span = Array(samples[windowStart..<samples.count])
                    let hyp = try self.transcriber!.transcribe(
                        samples: span, sampleRate: rate, verbose: false)
                    print("[transcribe] tail decode: win=\(String(format:"%.1f",Double(windowStart)/rate))s..end (\(String(format:"%.1f",Double(span.count)/rate))s), committed=\(self.committedCount)/\(self.shownWords.count)w, hyp=\"\(hyp)\"")
                    let hypEmpty = hyp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hypEmpty, Double(tailCount) > 2.0 * rate {
                        // >2s of uncommitted audio decoding to nothing is a decode
                        // failure, not silence — pay for the authoritative pass.
                        print("[transcribe] tail decode empty over \(Double(tailCount)/rate)s — full decode")
                        let rawText = try self.transcriber!.transcribe(
                            samples: samples, sampleRate: rate, verbose: false)
                        text = textPostProcessing(for: rawText)
                    } else {
                        let joined = self.applyFinalWindow(hypothesis: hyp)
                        text = textPostProcessing(for: joined)
                    }
                } else {
                    // Full decode: the stream never committed (short recording / no
                    // tick ran) — or it resynced heavily, meaning committed text may
                    // carry artifacts only an authoritative pass can repair.
                    if self.resyncCount >= 3 {
                        print("[transcribe] \(self.resyncCount) resyncs — full decode")
                    }
                    let rawText = try self.transcriber!.transcribe(
                        samples: samples, sampleRate: rate, verbose: false)
                    text = textPostProcessing(for: rawText)
                }
                DispatchQueue.main.async {
                    // Rewrite everything from the first divergence between what's in
                    // the field and the final decode — committed text that disagrees
                    // with the final transcript must not stay frozen in the document.
                    // `currentText` (not the streaming state) is ground truth here:
                    // a partial dropped at stop can leave shownText a tick ahead.
                    let keep = self.utf16CommonPrefix(self.inserter.currentText, text)
                    // Final write through AX (replaces only the divergent tail), then clipboard.
                    // Clipboard is set before the fallback so a needed ⌘V pastes text.
                    let mode = self.inserter.finish(text, keepPrefix: keep)
                    // An empty transcript (silence/accidental tap) must not clobber
                    // the user's clipboard, and a ⌘V fallback would paste stale text.
                    if !text.isEmpty {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    }
                    print("[transcribe] copied \(text.count) chars to clipboard; delivery=\(mode)")

                    if mode == .pasteFallback, !text.isEmpty {
                        // The focused field refused AX writes — fall back to ⌘V paste of
                        // the clipboard we just set (the old delivery mechanism).
                        LiveTextInserter.pasteClipboard()
                    }

                    self.finishTranscription()      // stop particles + slide window up
                }
            } catch {
                print("[transcribe] error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.finishTranscription() }
            }
        }
    }
    
    private func textPostProcessing(for text:String) -> String{
        if text.hasSuffix(".") || text.hasSuffix("。"){
            return String(text.dropLast())
        }else{
            return text
        }
    }
    
    private func switchWindowState(){
        switch windowState {
            case .hidden:
            moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height - screenInfo.fringeWidth))
            windowState = .expanded
                return
            case .expanded:
            moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height))
            windowState = .hidden
                return
            }
    }
    
    private func switchWindowState(to target: WindowState, completion: (() -> Void)? = nil){
        switch target {
            case .hidden:
                moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height),
                           completion: completion)
                windowState = .hidden
            case .expanded:
                moveWindow(to: NSPoint(x: (screenInfo.width - screenInfo.fringeWidth)/2, y: screenInfo.height - screenInfo.fringeWidth),
                           completion: completion)
                windowState = .expanded
            }
    }

    // MARK: - Particle overlay

    // Build a fresh particle view: a SpriteKit view inset 32 pt from the window edges
    // (the required padding) with a feathered circular mask so particles fade softly to
    // transparent toward a circle, with no hard edge. Created per-session and torn down
    // completely when the session ends, so nothing can carry over.
    private func makeParticleView() -> SKView? {
        guard let contentView = window.contentView else { return nil }
        let inset: CGFloat = 32
        let skView = SKView(frame: contentView.bounds.insetBy(dx: inset, dy: inset))
        skView.allowsTransparency = true            // let the black background show through
        skView.autoresizingMask = []                // window is fixed-size
        skView.wantsLayer = true
        let scene = SKScene(size: skView.bounds.size)
        scene.backgroundColor = .clear
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)

        let mask = CAGradientLayer()
        mask.type = .radial
        mask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        mask.locations = [0.0, 0.55, 1.0]
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1.0, y: 1.0)     // radius reaches the edge midpoints
        mask.frame = skView.bounds
        skView.layer?.mask = mask
        return skView
    }

    // Load the emitter from the .sks. `white` forces solid-white particles (overriding
    // the authored colour sequences) for the transcription phase; otherwise it's used
    // exactly as authored.
    private func makeEmitter(white: Bool) -> SKEmitterNode? {
        guard let scene = skView?.scene,
              let emitter = SKEmitterNode(fileNamed: "RecordAnimation") else { return nil }
        emitter.position = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
        if white {
            emitter.particleColorSequence = nil
            emitter.particleColorBlendFactorSequence = nil
            emitter.particleColor = .white
            emitter.particleColorBlendFactor = 1
        }
        return emitter
    }

    // Remove the entire particle layer from the window.
    private func removeParticleLayer() {
        skView?.removeFromSuperview()
        skView = nil
        recordEmitter = nil
    }

    // Recording: build a fresh particle view with the authored emitter, untouched.
    private func startRecordingParticles() {
        guard let contentView = window.contentView else { return }
        removeParticleLayer()                               // clean slate
        guard let skView = makeParticleView() else { return }
        contentView.addSubview(skView)
        self.skView = skView
        guard let emitter = makeEmitter(white: false) else {
            print("[particles] couldn't load RecordAnimation.sks"); return
        }
        skView.scene?.addChild(emitter)
        recordEmitter = emitter
    }

    // Transcription: crossfade the authored stream into a white one via node alpha, so
    // the authored colours are never mutated (no colour pop) and existing particles fade
    // out cleanly.
    private func transitionParticlesToWhite(duration: TimeInterval = 0.4) {
        guard let scene = skView?.scene, let outgoing = recordEmitter,
              let white = makeEmitter(white: true) else { return }
        white.alpha = 0
        scene.addChild(white)
        white.run(.fadeIn(withDuration: duration))
        outgoing.run(.sequence([.fadeOut(withDuration: duration), .removeFromParent()]))
        recordEmitter = white
    }

    // Called on the main thread once transcription finishes (paste) or errors.
    private func finishTranscription() {
        isTranscribing = false
        recordEmitter?.particleBirthRate = 0                // stop emitting new particles
        switchWindowState(to: .hidden) { [weak self] in
            self?.removeParticleLayer()                     // completely remove the particle layer
        }
        
        
        // Keep the transcriber resident: reloading the model per dictation leaks
        // ~15MB of MLX graph descriptors each cycle and adds load latency.
        transcribeQueue.async {
            Memory.clearCache()        // flush decode-time Metal buffer pool
        }
       
    }
    //Written by Claude, I don't know how it works
    private func keyPressInterception() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[tap] Accessibility trusted: \(trusted)")
        guard trusted else {
            // Don't leave the app half-dead: explain once, then silently arm the tap as
            // soon as the user grants — no restart needed, and no reprompt loop.
            let alert = NSAlert()
            alert.messageText = "Transcribe needs Accessibility access"
            alert.informativeText = "Grant it in System Settings → Privacy & Security → Accessibility. Once granted, the hotkey starts working automatically — no restart needed."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    print("[tap] Accessibility granted — arming hotkey")
                    self?.keyPressInterception()
                }
            }
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Mask covers keyDown + systemDefined (media keys sent by F-keys on
        // MacBooks) + flagsChanged so the watchdog's modifier probe can arrive.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
                   CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
                   CGEventMask(1 << 14) // 14 = systemDefined (media/function keys)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                // Any delivered event — our probe or real input — proves the
                // tap is alive. (Tagged probes were tried and never arrive: a
                // nonzero eventSourceUserData prevents delivery to our tap.)
                delegate.probePending = false
                // macOS disables a tap whose callback runs long (timeout) or that the
                // user/system disabled; without re-enabling, the next hotkey press is
                // silently swallowed.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = delegate.keyTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    print("[tap] re-enabled after disable event \(type.rawValue)")
                    return nil
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if type != .flagsChanged {   // modifiers + our own probes aren't interesting
                    print("[tap] event type: \(type.rawValue)  keyCode: \(keyCode)")
                }
                guard keyCode == 176 else {
                    return Unmanaged.passRetained(event)
                }
                DispatchQueue.main.async {
                    delegate.Action()
                }
                return nil
            },
            userInfo: selfPtr
        ) else {
            print("[tap] CGEvent.tapCreate failed")
            return
        }

        keyTap = tap   // kept for re-enable when the system disables the tap
        print("[tap] tap created successfully")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        keyTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startTapWatchdog()

        // Test hooks: simulate the two ways a tap dies so the watchdog's
        // recovery paths can be exercised deterministically. They fire once —
        // a rebuilt tap must not re-arm them.
        if tapTestFired { return }
        if CommandLine.arguments.contains("--tap-disable-test") {
            tapTestFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if let tap = self?.keyTap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    print("[tap] TEST: tap disabled")
                }
            }
        } else if CommandLine.arguments.contains("--tap-kill-test") {
            tapTestFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if let tap = self?.keyTap {
                    CFMachPortInvalidate(tap)
                    print("[tap] TEST: tap port invalidated")
                }
            }
        }
    }

    // The tap's disable notification is the fast path — but the port can also die
    // silently (all events stop arriving with no notification). The watchdog posts
    // a probe keycode through the tap every tick; a probe that never comes back
    // means the port is dead, so the whole tap is rebuilt.
    private func startTapWatchdog() {
        tapWatchdog?.invalidate()
        tapWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tapWatchdogTick()
        }
    }

    private func tapWatchdogTick() {
        if IsSecureEventInputEnabled() {
            if !secureInputActive {
                secureInputActive = true
                print("[tap] secure event input held by another app — hotkey hidden until released")
            }
            probePending = false
            return
        }
        if secureInputActive {
            secureInputActive = false
            print("[tap] secure input released — hotkey restored")
        }
        if probePending {
            probePending = false   // retry once more before declaring dead:
            postProbe()
            if probeLost {
                print("[tap] watchdog: probe lost — event tap is dead, rebuilding")
                probeLost = false
                rebuildTap()
            } else {
                probeLost = true
            }
            return
        }
        probeLost = false
        if let tap = keyTap {
            if !CFMachPortIsValid(tap) {
                print("[tap] watchdog: tap port invalid — rebuilding")
                rebuildTap()
                return
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                print("[tap] watchdog: tap disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        postProbe()
    }

    private func postProbe() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(tapProbeKeyCode), keyDown: false) else { return }
        ev.type = .flagsChanged
        ev.flags = []
        probePending = true
        ev.post(tap: .cghidEventTap)
    }

    private func rebuildTap() {
        if let src = keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let tap = keyTap {
            CFMachPortInvalidate(tap)
        }
        keyTap = nil
        keyTapSource = nil
        probePending = false
        keyPressInterception()
    }
    
    private func Action(){
        switch windowState {
        case .expanded:
            guard !isTranscribing else { return }       // ignore key presses while transcribing
            endRecord()
            isTranscribing = true
            transitionParticlesToWhite()                // green → white, window stays visible
            transcribe()                                // hides window on completion
        case .hidden:
            startRecord()
            switchWindowState(to: .expanded) { [weak self] in
                self?.startRecordingParticles()         // start AFTER the slide-down completes
            }
        }
    }

    private func moveWindow(to origin: NSPoint, completion: (() -> Void)? = nil) {
          let newFrame = NSRect(origin: origin, size: window.frame.size)
          NSAnimationContext.runAnimationGroup({ context in
              context.duration = 0.4
              context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
              window.animator().setFrame(newFrame, display: true)
          }, completionHandler: completion)
      }
    
}


/*
class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
 */


extension NSPanel{
    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
