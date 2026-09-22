import Cocoa
import Foundation
import ApplicationServices
import AlexTranscribeKit

/// Test harness for the streaming + Accessibility-insertion pipeline.
///
/// Modes:
///   feed <audio> <out.pcm>     Decode an audio file to raw Float32-LE 16 kHz mono PCM
///                              (the format TRANSCRIBE_TEST_PCM feeds into the app).
///   stream <audio> [tickSec]   Simulate the app's tick loop: re-transcribe the file at
///                              growing prefixes, print every partial + each tick's result.
///   insert <text>              One-shot AX insert into the focused element.
///   live <t1> <t2> ...         Drive LiveTextInserter with cumulative updates (0.5s apart)
///                              — pass revised texts to exercise range-replace.
///   focus                      Print the focused element's role and current value.
///   hotkey                     Post the dictation hotkey (keyCode 176) down+up.

func usage() -> Never {
    print("usage: transcribe-test <feed|stream|insert|live|focus|hotkey> ...")
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { usage() }

func modelDir() -> URL {
    if let dir = ProcessInfo.processInfo.environment["TRANSCRIBE_MODEL_DIR"] {
        return URL(fileURLWithPath: dir)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("models/Qwen3-ASR-1.7B-8bit")
}

/// Prompt for Accessibility trust if missing (AX writes + the event tap need it).
func requestAXTrust() {
    // AX element queries require the process to have a real app context — without
    // NSApplication the HIServices connection reports kAXErrorAPIDisabled (-25204)
    // even when the process is TCC-trusted. Initializing it is enough; no runloop
    // is needed for synchronous attribute calls.
    _ = NSApplication.shared
    // kAXTrustedCheckOptionPrompt as a C global is not concurrency-safe in Swift 6; use its literal value.
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    print("accessibility trusted: \(trusted)")
}

func loadPCM16k(_ path: String) throws -> [Float] {
    try loadAudio16kMono(url: URL(fileURLWithPath: path))
}

switch mode {
case "feed":
    guard args.count == 3 else { usage() }
    let samples = try loadPCM16k(args[1])
    var data = Data(capacity: samples.count * 4)
    for s in samples {
        var bits = s.bitPattern.littleEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    try data.write(to: URL(fileURLWithPath: args[2]))
    print("wrote \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s) -> \(args[2])")

case "raw":
    // Decode a raw Float32-LE 16 kHz mono PCM file (same format TRANSCRIBE_TEST_PCM uses).
    guard args.count == 2 else { usage() }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let audio = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let asr = try AlexTranscriber(modelDirectory: modelDir())
    print("audio: \(audio.count) samples (\(String(format: "%.1f", Double(audio.count) / 16000))s)")
    let final = try asr.transcribe(samples: audio, sampleRate: 16000, verbose: false)
    print("FINAL(\(final.count)): \(final)")

case "stream":
    guard args.count >= 2 else { usage() }
    let tickSec = args.count >= 3 ? Double(args[2]) ?? 1.8 : 1.8
    let audio = try loadPCM16k(args[1])
    let asr = try AlexTranscriber(modelDirectory: modelDir())
    print("audio: \(audio.count) samples (\(String(format: "%.1f", Double(audio.count) / 16000))s), tick=\(tickSec)s")

    var t = Int(tickSec * 16000)
    var tick = 0
    while t < audio.count {
        let prefix = Array(audio[0..<t])
        let t0 = Date()
        let out = try asr.transcribe(samples: prefix, sampleRate: 16000, verbose: false) { p in
            print("  [tick \(tick) partial] \(p)")
        }
        print("[tick \(tick)] \(String(format: "%.1f", Double(t) / 16000))s audio -> \"\(out)\" (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
        tick += 1
        t += Int(tickSec * 16000)
    }
    let final = try asr.transcribe(samples: audio, sampleRate: 16000, verbose: false) { p in
        print("  [final partial] \(p)")
    }
    print("FINAL: \(final)")

case "insert":
    guard args.count == 2 else { usage() }
    requestAXTrust()
    let ins = LiveTextInserter()
    ins.begin()
    ins.update(args[1])
    print("finish mode: \(ins.finish(args[1]))")

case "live":
    guard args.count >= 2 else { usage() }
    requestAXTrust()
    let ins = LiveTextInserter()
    ins.begin()
    for (i, text) in args.dropFirst().enumerated() {
        ins.update(text)
        print("[update \(i)] wrote: \(text)")
        Thread.sleep(forTimeInterval: 0.5)
    }
    let result = ins.finish(args.last!)
    print("finish mode: \(result)")

case "focus":
    requestAXTrust()
    let sys = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref)
    guard err == .success, let el = ref else {
        print("no focused element (err=\(err.rawValue))")
        exit(0)
    }
    let element = el as! AXUIElement
    var role: CFTypeRef?, value: CFTypeRef?, app: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    AXUIElementCopyAttributeValue(element, kAXTopLevelUIElementAttribute as CFString, &app)
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
    print("role: \(role ?? "?" as CFTypeRef)")
    print("selectedText settable: \(settable.boolValue)")
    print("value: \(value ?? "<nil>" as CFTypeRef)")

case "hotkey":
    // Post the dictation hotkey the app's event tap listens for (keyCode 176).
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 176, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 176, keyDown: false)
    down?.post(tap: .cghidEventTap)
    usleep(60000)
    up?.post(tap: .cghidEventTap)
    print("posted hotkey 176")

default:
    usage()
}
