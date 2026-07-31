import Foundation

protocol Transcriber {
    var modelID: String { get }
    /// Downloads if needed and loads into memory, so the first hotkey press is
    /// not the thing that waits.
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
    /// Releases the loaded weights. Switching models calls this on the outgoing
    /// engine so two models never sit in memory at once.
    func unload() async
}
