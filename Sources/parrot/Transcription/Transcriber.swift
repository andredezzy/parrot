import Foundation

protocol Transcriber {
    var modelID: String { get }
    /// Downloads if needed and loads into memory, so the first hotkey press is
    /// not the thing that waits. `onProgress` reports the download as a fraction
    /// so a switch that takes minutes can say so; loading afterwards is silent
    /// because neither engine reports it.
    func warmUp(onProgress: (@Sendable (Double) -> Void)?) async throws
    /// `language` pins the decode. Nil lets the engine decide, which is what
    /// dictation wants and what a caller transcribing a known-language file
    /// must not accept: unpinned, Whisper translates instead of transcribing.
    func transcribe(_ audio: [Float], language: String?) async throws -> String
    /// Releases the loaded weights. Switching models calls this on the outgoing
    /// engine so two models never sit in memory at once.
    func unload() async
}
