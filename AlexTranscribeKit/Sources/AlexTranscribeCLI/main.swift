import Foundation
import AlexTranscribeKit

let cwd = FileManager.default.currentDirectoryPath
let root = URL(fileURLWithPath: cwd)
let modelDir = root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit")
let audioPath = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Samples/voice.mp3")

print("== Qwen3-ASR-1.7B-8bit (pure Swift / MLX) ==")
print("model dir: \(modelDir.path)")
print("audio:     \(audioPath.path)")

do {
    let asr = try AlexTranscriber(modelDirectory: modelDir)
    let text = try asr.transcribe(audioURL: audioPath, verbose: true)
    print("\n================ TRANSCRIPTION ================")
    print(text)
    print("==============================================")
} catch {
    print("ERROR: \(error)")
    exit(1)
}
