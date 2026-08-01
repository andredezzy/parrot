import Foundation

/// A sentence or two in the user's own words, handed to the model before it
/// decodes. Whisper conditions on it the way it conditions on the previous
/// window of a long recording, which is why the file holds an *example* of
/// speech rather than a description of the speaker.
///
/// That distinction is the whole feature. Measured on eight utterances:
/// "Sou desenvolvedor de software. Falo de pull requests, merge, deploy"
/// recovered 62% of technical terms, while "Preciso revisar os pull requests
/// antes do merge. Depois vou fazer o deploy do backend" recovered 85%.
/// Describing yourself is worth a little; showing the model a sentence it
/// should expect is worth a lot.
struct DictationExample {
    static let file = ModelWeights.root.appending(path: "dictation-example.txt")

    let text: String

    var isEmpty: Bool { text.isEmpty }

    init(contentsOf url: URL = DictationExample.file) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
    }

    static let template = """
        # Write a sentence or two the way you actually dictate, using the words
        # you want spelled correctly. The model reads this as speech that came
        # just before yours, so an example works and a description does not:
        #
        #   this works    Preciso revisar os pull requests antes do merge.
        #                 Depois vou fazer o deploy do backend.
        #
        #   this doesn't  Sou desenvolvedor e uso termos técnicos em inglês.
        #
        # Lines starting with # are ignored. Applies to Whisper models only —
        # Parakeet has no way to read it.

        """

    /// Created on first open so the format is explained in the file itself
    /// rather than somewhere the user has to go looking.
    static func ensureFileExists() throws {
        let path = file.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try template.write(to: file, atomically: true, encoding: .utf8)
    }
}
