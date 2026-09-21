//
//  AppDelegate.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-04.
//

import AppKit
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
    private let tickAudioInterval: Double = 1.8   // seconds
    /// Don't start partial passes until this much audio exists (also clears the mel
    /// front-end's 201-sample minimum with margin).
    private let minTickAudio: Double = 1.0        // seconds

    // Particle overlay shown inside the window during record + transcribe.
    private var skView: SKView?
    private var recordEmitter: SKEmitterNode?
    private var isTranscribing = false
    private var keyTap: CFMachPort?

    private func initScreeninfo(){
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        
        screenInfo = ScreenInfo(width: fullFrame.width,
                                height: fullFrame.height,
                                fringeWidth: 184)
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
        streamLock.unlock()
        transcribeQueue.async { [weak self] in self?.streamingLoop(session: session) }
    }

    /// Re-transcribe the growing capture every `tickAudioInterval` seconds of new audio.
    /// Runs on transcribeQueue until endRecord clears `streamingActive`; an in-flight
    /// pass aborts early via `isCancelled` so the final pass can start promptly.
    private func streamingLoop(session: Int) {
        while isStreamingActive() {
            let (samples, rate) = recorder.snapshot()
            if let t = transcriber,
               Double(samples.count) >= minTickAudio * rate,
               Double(samples.count - lastTickSampleCount) >= tickAudioInterval * rate {
                lastTickSampleCount = samples.count
                do {
                    _ = try t.transcribe(
                        samples: samples, sampleRate: rate, verbose: false,
                        onPartialText: { [weak self] partial in self?.emitPartial(partial, session: session) },
                        isCancelled: { [weak self] in !(self?.isStreamingActive() ?? false) })
                } catch {
                    print("[stream] tick failed: \(error.localizedDescription)")
                }
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// Route a cleaned partial transcript into the focused field via the AX inserter.
    /// Serial-queue → main dispatch keeps emissions in order; the session check drops
    /// stragglers from an already-finished session.
    private func emitPartial(_ text: String, session: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == session else { return }
            self.inserter.update(text)
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
                let rawText = try self.transcriber!.transcribe(
                    samples: samples, sampleRate: rate, verbose: false,
                    onPartialText: { [weak self] partial in self?.emitPartial(partial, session: session) })
                // Drop the ending . and 。
                let text = textPostProcessing(for: rawText)
                DispatchQueue.main.async {
                    // Final write through AX (replaces the last partial), then clipboard.
                    // Clipboard is set before the fallback so a needed ⌘V pastes text.
                    let mode = self.inserter.finish(text)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    print("[transcribe] copied \(text.count) chars to clipboard; delivery=\(mode)")

                    if mode == .pasteFallback {
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
        
        
        //Remove the model from memory
        print("Removing transcriber")
        self.transcriber = nil
        transcribeQueue.async { [weak self] in
                self?.transcriber = nil
                Memory.clearCache()        // flush Metal buffer pool
            }
       
    }
    //Written by Claude, I don't know how it works
    private func keyPressInterception() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[tap] Accessibility trusted: \(trusted)")
        guard trusted else {
            print("[tap] Grant Accessibility permission then restart the app")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Mask covers keyDown + systemDefined (media keys sent by F-keys on MacBooks)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
                   CGEventMask(1 << 14) // 14 = systemDefined (media/function keys)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
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
                print("[tap] event type: \(type.rawValue)  keyCode: \(keyCode)")
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
