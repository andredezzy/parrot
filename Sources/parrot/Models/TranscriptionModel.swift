import Foundation

enum Engine: String, Codable {
    case whisperKit
    case parakeet
    /// Whisper again, but through whisper.cpp: beam search on Metal rather than a
    /// greedy pass on the ANE. Slower per phrase, and the only engine here that
    /// keeps more than one candidate sentence alive.
    case whisperCpp
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    /// The id the engine itself knows the model by.
    let engineID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
}

struct ModelsManifest: Codable {
    let models: [TranscriptionModel]
}
