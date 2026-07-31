import AVFoundation
import Foundation
import Speech

// DictationTranscriber is the only engine on this machine with working positive
// biasing. Does contextualStrings actually fix the misheard terms?

let dir = "/tmp/parrot-samples"
let cases: [(String, String)] = [("02.wav", "en-US"), ("04.wav", "pt-BR"), ("05.wav", "pt-BR")]
let hints = ["pull request", "pull requests", "backend", "merge", "deploy"]

func run(_ path: String, locale: Locale, bias: [String]) async -> (String, Double) {
    let started = Date()
    do {
        let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
        let context = AnalysisContext()
        if !bias.isEmpty { context.contextualStrings = [.general: bias] }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], options: nil, analysisContext: context, finishAfterFile: true)
        let collector = Task { () -> String in
            var out: [String] = []
            for try await r in transcriber.results { out.append(String(r.text.characters)) }
            return out.joined(separator: " ")
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = (try? await collector.value) ?? ""
        return (text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), Date().timeIntervalSince(started))
    } catch {
        return ("<erro: \(error)>", Date().timeIntervalSince(started))
    }
}

print("dicas: \(hints.joined(separator: ", "))\n")
for (wav, id) in cases {
    let locale = Locale(identifier: id)
    let (plain, t1) = await run("\(dir)/\(wav)", locale: locale, bias: [])
    let (biased, t2) = await run("\(dir)/\(wav)", locale: locale, bias: hints)
    print("┌─ \(wav) [\(id)]")
    print(String(format: "│  sem dicas (%.2fs): %@", t1, plain as NSString))
    print(String(format: "└  com dicas (%.2fs): %@\n", t2, biased as NSString))
}
