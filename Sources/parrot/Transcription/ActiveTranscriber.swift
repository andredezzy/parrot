import Foundation

/// The engine dictation currently speaks to, and the only thing that knows how
/// to replace it while the daemon keeps running.
///
/// Switching is serialised against transcription by the actor itself: a press
/// that lands mid-switch waits for the new model rather than racing a
/// half-unloaded one.
actor ActiveTranscriber {
    private(set) var model: TranscriptionModel
    private var transcriber: Transcriber

    init(model: TranscriptionModel) {
        self.model = model
        self.transcriber = Self.make(model)
    }

    private static func make(_ model: TranscriptionModel) -> Transcriber {
        switch model.engine {
        case .whisperKit: WhisperKitTranscriber(model: model)
        case .parakeet: ParakeetTranscriber(model: model)
        }
    }

    func warmUp() async throws {
        try await transcriber.warmUp()
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        try await transcriber.transcribe(audio)
    }

    /// Loads `next` before dropping the current engine, so a download that fails
    /// leaves the user dictating with what they already had.
    func use(_ next: TranscriptionModel) async throws {
        guard next.id != model.id else { return }
        let incoming = Self.make(next)
        try await incoming.warmUp()

        await transcriber.unload()
        transcriber = incoming
        model = next

        let reclaimed = ModelWeights.purge(keeping: next)
        if reclaimed > 0 {
            FileHandle.standardError.write(Data(
                "freed \(ModelWeights.describe(bytes: reclaimed)) of unused models\n".utf8))
        }
    }
}
