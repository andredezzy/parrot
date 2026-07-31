import AVFoundation
import Foundation
import Speech

// Apple's macOS 26 on-device engine on the same corpus parrot was measured on.
// No download, no model management: the OS owns the model.

let dir = "/tmp/parrot-samples"
let wavs = try FileManager.default.contentsOfDirectory(atPath: dir)
    .filter { $0.hasSuffix(".wav") }.sorted()

print("SpeechTranscriber locales instalados: \(SpeechTranscriber.installedLocales.count)")
let wanted = ["pt-BR", "en-US"]
for id in wanted {
    let locale = Locale(identifier: id)
    let installed = SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    print("  \(id): instalado=\(installed) suportado=\(supported)")
}

func transcribe(_ path: String, locale: Locale) async -> (String, Double) {
    let started = Date()
    do {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        // Analyzer without an input: feed the file once via analyzeSequence(from:).
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> String in
            var pieces: [String] = []
            for try await result in transcriber.results {
                pieces.append(String(result.text.characters))
            }
            return pieces.joined(separator: " ")
        }
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = (try? await collector.value) ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(started))
    } catch {
        return ("<erro: \(error)>", Date().timeIntervalSince(started))
    }
}
// Ground truth language of each sample, so Apple's one-locale-per-session limit
// is given its best case rather than a handicap.
let lang = ["01.wav": "en-US", "02.wav": "en-US", "03.wav": "pt-BR", "04.wav": "pt-BR",
            "05.wav": "pt-BR", "06.wav": "en-US", "07.wav": "pt-BR", "08.wav": "en-US"]

for wav in wavs {
    let id = lang[wav] ?? "en-US"
    let (text, elapsed) = await transcribe("\(dir)/\(wav)", locale: Locale(identifier: id))
    print(String(format: "ROW|%@|%@|%.2fs|%@", wav as NSString, id as NSString, elapsed, text as NSString))
}
print("DONE")
