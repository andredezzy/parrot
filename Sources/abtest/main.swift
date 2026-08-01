import Foundation
import WhisperKit

// Does transcription stop at the 30 s window boundary? 93.9 s of audio whose
// content is known: the 8-sample corpus repeated three times. If only the first
// window is transcribed, the tail is missing and the count of "Testing and
// speaking in English" occurrences will be 1 instead of 3.

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/long.wav"
let store = URL.applicationSupportDirectory.appending(path: "parrot/huggingface")
let model = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
    : "openai_whisper-large-v3-v20240930_turbo_632MB"

let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
print("áudio: \(String(format: "%.1f", Double(audio.count) / 16000))s · modelo: \(model)")

let pipeline = try await WhisperKit(WhisperKitConfig(
    model: model, downloadBase: store, verbose: false, prewarm: false, load: true
))
print("READY")

// Exactly what parrot does today.
let started = Date()
let results = try await pipeline.transcribe(audioArray: audio)
let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
print(String(format: "levou %.2fs · %d resultado(s) · %d segmentos",
             Date().timeIntervalSince(started), results.count,
             results.reduce(0) { $0 + $1.segments.count }))
if let last = results.last?.segments.last {
    print(String(format: "último segmento termina em %.1fs de %.1fs de áudio",
                 last.end, Double(audio.count) / 16000))
}
let marker = "speaking in English"
print("ocorrências de \"\(marker)\": \(text.components(separatedBy: marker).count - 1) (esperado 3)")
print("--- texto ---")
print(text)
