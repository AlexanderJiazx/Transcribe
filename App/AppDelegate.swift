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
    
    var audioData: Data?
    private let recorder = VoiceRecorder()
    
    private var transcriber: AlexTranscriber?
    
    private let transcribeQueue = DispatchQueue(label: "transcribe", qos: .userInitiated)  // ← add

    // Particle overlay shown inside the window during record + transcribe.
    private var skView: SKView?
    private var recordEmitter: SKEmitterNode?
    private var isTranscribing = false

    private func initScreeninfo(){
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        
        screenInfo = ScreenInfo(width: fullFrame.width,
                                height: fullFrame.height,
                                fringeWidth: 184)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // requestPermission() prompts only when status is .notDetermined; it returns
        // false outright if access was previously denied or restricted.
        Task { @MainActor in
            guard await recorder.requestPermission() else {
                print("[record] microphone access denied — enable it in System Settings")
                return
            }
            do {
                audioData = nil                 // discard any previous capture
                try recorder.start()
                print("[record] recording started")
            } catch {
                print("[record] couldn't start: \(error.localizedDescription)")
            }
        }
    }

    private func makeWAV(_ samples: [Float], sampleRate: Double) -> Data {
        // Encode the captured mono float samples as a 16-bit PCM WAV in memory.
        // AlexTranscriber.transcribe(audioData:) parses WAV directly and resamples to 16 kHz.
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let rate = UInt32(sampleRate)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = rate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)

        var d = Data()
        d.reserveCapacity(44 + Int(dataSize))
        func append32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func append16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func appendStr(_ s: String) { d.append(contentsOf: s.utf8) }

        appendStr("RIFF"); append32(36 + dataSize); appendStr("WAVE")
        appendStr("fmt "); append32(16); append16(1)        // Subchunk1Size, PCM
        append16(numChannels); append32(rate); append32(byteRate)
        append16(blockAlign); append16(bitsPerSample)
        appendStr("data"); append32(dataSize)

        for s in samples {
            let clamped = Swift.max(-1, Swift.min(1, s))
            var i = Int16(clamped * 32767).littleEndian
            d.append(Data(bytes: &i, count: 2))
        }
        return d
    }
    
    private func endRecord(){
        //End recording, save the recording to audioData
        guard recorder.isRecording else { return }
        let (samples, sampleRate) = recorder.stop()

        // The mel front-end reflect-pads by 200 samples, so inputs shorter than that crash
        // with "Index out of range". Skip accidental ultra-short taps (also pointless to
        // transcribe). Leaving audioData == nil makes transcribe()'s guard reset the UI.
        let minDuration = 0.2  // seconds
        guard Double(samples.count) >= minDuration * sampleRate else {
            print("[record] too short (\(samples.count) samples) — skipping transcription")
            return
        }

        audioData = makeWAV(samples, sampleRate: sampleRate)
        print("[record] captured \(String(format: "%.1f", Double(samples.count) / sampleRate))s")
    }

    private func transcribe(){
        //Transcribe audioData and save the result to user clipboard
        guard let audioData else {
            print("[transcribe] no audio to transcribe")
            finishTranscription()       // don't leave the window stuck expanded
            return
        }
        transcribeQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.transcriber == nil {
                    self.transcriber = try AlexTranscriber()   // bundled model, loaded once
                }
                let text = try self.transcriber!.transcribe(audioData: audioData)
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    print("[transcribe] copied \(text.count) chars to clipboard")

                    // Paste into the frontmost app by synthesizing ⌘V. The non-activating
                    // panel keeps focus on the previous app, so the paste lands there.
                    let src = CGEventSource(stateID: .combinedSessionState)
                    let vKey: CGKeyCode = 9   // kVK_ANSI_V
                    let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
                    let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
                    down?.flags = .maskCommand
                    up?.flags = .maskCommand
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)

                    self.finishTranscription()      // stop particles + slide window up
                }
            } catch {
                print("[transcribe] error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.finishTranscription() }
            }
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
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                print("[tap] event type: \(type.rawValue)  keyCode: \(keyCode)")
                guard keyCode == 176 else {
                    return Unmanaged.passRetained(event)
                }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
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
