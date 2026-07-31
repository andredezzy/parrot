import FoundationModels
import Foundation

// Can the on-device model fix code-switched technical terms without a maintained
// list, without translating, and fast enough for dictation?

let model = SystemLanguageModel.default
print("disponibilidade: \(model.availability)")
guard case .available = model.availability else {
    print("indisponível — nada a medir")
    exit(1)
}

let instructions = """
You repair speech-to-text output. Fix misheard technical terms and obvious \
transcription errors. Keep the original language of every word: never translate. \
Do not add, remove or reorder ideas. Do not explain. Reply with the corrected \
text only.
"""

// The eight transcriptions parrot actually produced.
let cases = [
    "Testing and speaking in English",
    "Let me share the pull request.",
    "Bom dia, tudo certo por aqui",
    "Preciso revisá-los por request antes do merge.",
    "O deploy do back-end quebrou de novo.",
    "Yes. Sing.",
    "Testando, falando uma frase longa em português Pra gente testar as nossas correções e etc",
    "Now test me speaking a long phrase in English so we can test your corrections and fixes.",
]

for (i, input) in cases.enumerated() {
    let session = LanguageModelSession(instructions: instructions)
    let started = Date()
    do {
        let response = try await session.respond(to: input)
        let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        print(String(format: "\n[%02d] %.2fs", i + 1, Date().timeIntervalSince(started)))
        print("  in : \(input)")
        print("  out: \(out)")
    } catch {
        print("\n[\(i + 1)] falhou: \(error)")
    }
}
