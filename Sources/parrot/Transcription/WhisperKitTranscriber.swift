import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    /// Earlier versions downloaded into WhisperKit's `Documents` default. Say so
    /// once rather than silently re-downloading gigabytes behind the user's back.
    static let legacyModelStore = URL.documentsDirectory.appending(path: "huggingface")


    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let engineID = model.engineID else {
            throw TranscriberError.missingEngineID
        }
        Self.noteLegacyStore()
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(
            model: engineID,
            downloadBase: ModelWeights.whisperKitBase,
            verbose: false,
            prewarm: true,
            load: true
        )
        pipeline = try await WhisperKit(config)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    /// Point at leftover models from the old `Documents` location so the disk
    /// space is reclaimable instead of just abandoned.
    private static func noteLegacyStore() {
        let path = legacyModelStore.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        FileHandle.standardError.write(Data(
            "models now live in \(ModelWeights.whisperKitBase.path(percentEncoded: false)) — \(path) is unused, delete it to reclaim space\n".utf8
        ))
    }

    func unload() async {
        pipeline = nil
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioArray: audio, decodeOptions: DecodingOptions(promptTokens: promptTokens()))
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// Read per dictation so editing the file takes effect on the next phrase.
    /// Special tokens are dropped: the decoder builds its own control sequence
    /// around this text, and a stray one there desynchronises it.
    private func promptTokens() -> [Int]? {
        let example = DictationExample()
        guard !example.isEmpty, let tokenizer = pipeline?.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + example.text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
