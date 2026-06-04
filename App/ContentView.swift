import AppKit
import AlexTranscribeKit

/// AppKit demo: a record button that captures the mic into memory, then transcribes and
/// displays the text. The model loads once (lazily) and is reused.
final class RecorderViewController: NSViewController {
    private let recorder = VoiceRecorder()
    private var transcriber: AlexTranscriber?            // loaded once, lazily
    private let work = DispatchQueue(label: "transcribe", qos: .userInitiated)

    private let recordButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let transcriptScroll = NSTextView.scrollableTextView()
    private var transcriptView: NSTextView { transcriptScroll.documentView as! NSTextView }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 440))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        setIdle()
    }

    // MARK: UI

    private func buildUI() {
        let title = NSTextField(labelWithString: "AlexTranscribe")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center

        recordButton.bezelStyle = .regularSquare
        recordButton.imagePosition = .imageAbove
        recordButton.imageScaling = .scaleProportionallyUpOrDown
        recordButton.font = .systemFont(ofSize: 14, weight: .semibold)
        recordButton.target = self
        recordButton.action = #selector(toggle)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.hasVerticalScroller = true
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.textContainerInset = NSSize(width: 8, height: 8)

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY

        for v in [title, recordButton, statusRow, transcriptScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            recordButton.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 100),
            recordButton.heightAnchor.constraint(equalToConstant: 96),

            statusRow.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 12),
            statusRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            transcriptScroll.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 14),
            transcriptScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            transcriptScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            transcriptScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    private func applyButton(symbol: String, label: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        recordButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        recordButton.title = label
        recordButton.contentTintColor = color
    }

    private func setIdle() {
        recordButton.isEnabled = true
        applyButton(symbol: "mic.circle.fill", label: "Record", color: .controlAccentColor)
        statusLabel.stringValue = "Tap Record to start"
        spinner.stopAnimation(nil); spinner.isHidden = true
    }

    private func setRecording() {
        recordButton.isEnabled = true
        applyButton(symbol: "stop.circle.fill", label: "Stop", color: .systemRed)
        statusLabel.stringValue = "Recording… tap Stop to finish"
        spinner.stopAnimation(nil); spinner.isHidden = true
    }

    private func setWorking(_ message: String) {
        recordButton.isEnabled = false
        statusLabel.stringValue = message
        spinner.isHidden = false; spinner.startAnimation(nil)
    }

    // MARK: Actions

    @objc private func toggle() {
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // If access was previously denied, macOS won't re-prompt — send the user to Settings.
        if recorder.permissionStatus == .denied || recorder.permissionStatus == .restricted {
            statusLabel.stringValue = "Microphone access is off — enable it in System Settings."
            openMicrophoneSettings()
            return
        }
        Task { @MainActor in
            guard await recorder.requestPermission() else {
                statusLabel.stringValue = "Microphone access was denied."
                openMicrophoneSettings()
                return
            }
            do {
                try recorder.start()
                transcriptView.string = ""
                setRecording()
            } catch {
                statusLabel.stringValue = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopAndTranscribe() {
        let (samples, sampleRate) = recorder.stop()
        let seconds = Double(samples.count) / sampleRate
        setWorking(String(format: "Transcribing %.1fs of audio…", seconds))

        work.async { [weak self] in
            guard let self else { return }
            do {
                if self.transcriber == nil {
                    DispatchQueue.main.async { self.statusLabel.stringValue = "Loading model (first run)…" }
                    self.transcriber = try AlexTranscriber()          // bundled model, auto-loaded
                }
                let text = try self.transcriber!.transcribe(samples: samples, sampleRate: sampleRate)
                DispatchQueue.main.async {
                    self.transcriptView.string = text.isEmpty ? "(no speech detected)" : text
                    self.setIdle()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                    self.setIdle()
                }
            }
        }
    }
}
