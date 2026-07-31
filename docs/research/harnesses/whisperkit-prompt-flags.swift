import Foundation
import WhisperKit

// Throwaway A/B rig: decode one recording under several DecodingOptions so the
// language settings can be compared on real audio instead of argued about.

let wavPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/parrot-last.wav"
let store = URL.applicationSupportDirectory.appending(path: "parrot/huggingface")

let glossary = """
Pull request, merge, deploy, backend, frontend, commit, branch, review, \
TypeScript, Swift, build, release, endpoint, deploy no backend.
"""

// The user's idea: one fixed sentence of context that never grows, instead of
// a word list someone has to keep feeding.
let context = """
Ditado de um engenheiro de software brasileiro, falando português e usando \
termos técnicos de programação em inglês.
"""

let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: wavPath)
print("audio: \(String(format: "%.2f", Double(audio.count) / 16000))s\n")

let pipeline = try await WhisperKit(WhisperKitConfig(
    model: "openai_whisper-large-v3-v20240930_turbo",
    downloadBase: store,
    verbose: false,
    prewarm: false,
    load: true
))
let promptTokens = pipeline.tokenizer?.encode(text: " " + glossary)
    .filter { $0 < (pipeline.tokenizer?.specialTokens.specialTokenBegin ?? Int.max) }
print("glossary tokens: \(promptTokens?.count ?? 0)\n")
let contextTokens = pipeline.tokenizer?.encode(text: " " + context)
    .filter { $0 < (pipeline.tokenizer?.specialTokens.specialTokenBegin ?? Int.max) }
print("context tokens: \(contextTokens?.count ?? 0)")

func run(_ label: String, _ options: DecodingOptions) async {
    let started = Date()
    do {
        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = results.first?.language ?? "?"
        print(String(format: "%-34@  %.2fs  lang=%@", label as NSString,
                     Date().timeIntervalSince(started), lang as NSString))
        print("    \(text)\n")
    } catch {
        print("\(label): FALHOU \(error)\n")
    }
}

// What parrot ships today (pins <|en|>) versus not lying about the language.
await run("1 baseline (parrot hoje)", DecodingOptions())
await run("2 detectLanguage", DecodingOptions(detectLanguage: true))
await run("3 language=pt (referencia)", DecodingOptions(language: "pt"))
