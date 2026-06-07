import AppKit
import AVFoundation

// Pure-AppKit entry point. Builds an NSWindow hosting the record-button demo
// (`RecorderViewController`); the transcription work lives in `AlexTranscribeKit`.
@main
enum AlexTranscribeMain {
    static func main() {
        
        let screen = NSScreen.main!
        let fullFrame = screen.frame
        let width = fullFrame.width
        let height = fullFrame.height
        print("Width: \(width)\nHeight: \(height)")
        
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // show in Dock, allow activation
        app.run()
    }
}

/*
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for microphone access as early as possible (macOS equivalent of the iOS
        // AVAudioSession.requestRecordPermission snippet — AVAudioSession does not exist on macOS).
        let diag = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("alextranscribe_micdiag.txt")
        let before = AVCaptureDevice.authorizationStatus(for: .audio)
        try? "appDelegate before=\(before.rawValue)\n".write(to: diag, atomically: true, encoding: .utf8)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            let after = AVCaptureDevice.authorizationStatus(for: .audio)
            try? "appDelegate before=\(before.rawValue) granted=\(granted) after=\(after.rawValue)\n"
                .write(to: diag, atomically: true, encoding: .utf8)
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AlexTranscribe"
        window.contentViewController = RecorderViewController()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
*/
