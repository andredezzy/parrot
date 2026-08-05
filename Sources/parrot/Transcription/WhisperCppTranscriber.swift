import Foundation
import whispercpp

/// Whisper through whisper.cpp, on Metal, with beam search.
///
/// The third engine here rather than a replacement for the second, because the two
/// answer different questions. WhisperKit decodes greedily on the ANE and returns a
/// dictated phrase in about 300ms; this one keeps five candidate sentences alive and
/// scores them whole, which costs latency and buys the words a greedy pass drops.
///
/// Measured on a 2m16s Portuguese note against faster-whisper, which is beam-5 on
/// CPU and the accuracy this is trying to match:
///
///     clean speech      94.2% both, 25s here against 91s there
///     degraded speech   89.4% here, 88.5% there, 24s against 279s
///     uneven levels     82.7% here, 68.9% there, 18s against 115s
///
/// The third row is the one that needed `LevelNormalizer` to get there; untouched it
/// scores 52.2%, because a passage recorded quietly reads to Whisper as silence.
actor WhisperCppTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var context: OpaquePointer?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    func warmUp(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if context != nil { return }
        guard let directory = ModelWeights.directory(of: model) else {
            throw TranscriberError.missingEngineID
        }
        let weights = directory.appending(path: "\(model.engineID ?? model.id).bin")
        guard FileManager.default.fileExists(atPath: weights.path(percentEncoded: false)) else {
            throw TranscriberError.notLoaded
        }

        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        var params = whisper_context_default_params()
        params.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(
            weights.path(percentEncoded: false), params
        ) else {
            throw TranscriberError.notLoaded
        }
        context = ctx
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float], language requested: String?) async throws -> String {
        if context == nil { try await warmUp() }
        guard let context else { throw TranscriberError.notLoaded }

        // Whisper hears a quiet passage as silence and returns nothing for it, while
        // the sentences either side still read as sentences — so the transcript looks
        // whole. Levelling first is worth 30 points on a file with uneven volume and
        // costs nothing on one already even, which LevelNormalizer detects and skips.
        let levelled = LevelNormalizer.normalize(audio)

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.translate = false
        // Left to detect for itself the model translates rather than transcribes,
        // returning Portuguese speech as English sentences. Nil means the caller
        // genuinely does not know, which is the only case worth guessing in.
        params.detect_language = requested == nil
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

        let text: String = try requested.withCString { languageCString in
            params.language = languageCString
            let status = levelled.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
            guard status == 0 else { throw TranscriberError.notLoaded }

            var pieces: [String] = []
            for segment in 0..<whisper_full_n_segments(context) {
                if let raw = whisper_full_get_segment_text(context, segment) {
                    pieces.append(String(cString: raw))
                }
            }
            return pieces.joined()
        }
        return WhisperKitTranscriber.sanitize(text)
    }

    func unload() async {
        if let context { whisper_free(context) }
        context = nil
    }
}

private extension Optional where Wrapped == String {
    /// `whisper_full_params.language` borrows the pointer for the call's duration, so
    /// the string has to outlive it. A `withCString` on the optional keeps that
    /// lifetime honest instead of handing over a dangling temporary.
    func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let self else { return try body(nil) }
        return try self.withCString { try body($0) }
    }
}
