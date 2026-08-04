import AVFoundation
import ArgumentParser
import Foundation

/// Transcribes files that already exist, rather than speech captured from the mic.
///
/// Dictation is the reason parrot exists, but the model it loads to serve the `fn`
/// key is the same one an agent needs to read a voice note someone sent. Without
/// this, that agent installs a second engine and downloads a second copy of the
/// weights already sitting on disk.
///
/// Takes several files on purpose: loading Parakeet costs seconds and transcribing
/// costs milliseconds, so a folder handed over in one call is the difference
/// between one warm-up and twenty.
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe audio files. Reads from disk, prints to stdout."
    )

    @Argument(help: "Audio files to transcribe.")
    var files: [String]

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    // Left to detect for itself, Whisper answers a Portuguese voice note in
    // English sentences. A caller transcribing a file knows the language and
    // should say it; dictation, which does not, keeps the detection path.
    @Option(name: .long, help: "Language code to pin the decode to, e.g. pt. Detected when omitted.")
    var language: String?

    func run() throws {
        guard !files.isEmpty else {
            FileHandle.standardError.write(Data("no files given\n".utf8))
            throw ExitCode(1)
        }

        let store = ModelStore()
        guard let chosen = store.resolved(flag: model) else {
            if let id = model {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
            } else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
            }
            throw ExitCode(1)
        }

        // Decoding first means a path typo fails before the model spends seconds
        // loading, and a bad file in a batch of twenty is reported while the
        // terminal is still in front of whoever typed it.
        let decoded = try files.map { path -> (name: String, samples: [Float]) in
            let url = URL(fileURLWithPath: path)
            return (url.lastPathComponent, try Self.samples(from: url))
        }

        let transcriber = ActiveTranscriber(model: chosen)
        let label = files.count > 1

        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
                for file in decoded {
                    let text = try await transcriber.transcribe(file.samples, language: language)
                    if label { print("--- \(file.name)") }
                    print(text)
                }
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()
        if let failure {
            FileHandle.standardError.write(Data("\(failure)\n".utf8))
            throw ExitCode(1)
        }
    }

    /// Whatever the file holds, as mono 16 kHz floats — the one shape every engine here takes.
    ///
    /// macOS decodes Ogg/Opus natively (verified on 15.x with a WhatsApp voice
    /// note), so a `.ogg` needs no ffmpeg detour. It arrives at 48 kHz, which is
    /// why the resample is unconditional rather than a special case.
    private static func samples(from url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscribeError.missing(url.path)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscribeError.undecodable(url.lastPathComponent, error.localizedDescription)
        }

        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscribeError.undecodable(url.lastPathComponent, "unsupported format")
        }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(file.length) * ratio).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw TranscribeError.undecodable(url.lastPathComponent, "buffer allocation failed")
        }

        var readError: Error?
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            // The file's own position decides when it is spent. Reading past the
            // end of a WhatsApp Opus note throws instead of returning zero frames,
            // so a decoder that waits for the empty read reports a decode failure
            // on audio it already converted in full.
            guard file.framePosition < file.length else {
                status.pointee = .endOfStream
                return nil
            }
            guard let chunk = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 8192) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: chunk)
            } catch {
                readError = error
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = chunk.frameLength == 0 ? .endOfStream : .haveData
            return chunk.frameLength == 0 ? nil : chunk
        }

        if let readError {
            throw TranscribeError.undecodable(url.lastPathComponent, readError.localizedDescription)
        }
        if let conversionError {
            throw TranscribeError.undecodable(url.lastPathComponent, conversionError.localizedDescription)
        }
        guard let channel = output.floatChannelData?[0] else {
            throw TranscribeError.undecodable(url.lastPathComponent, "no samples decoded")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum TranscribeError: Error, CustomStringConvertible {
    case missing(String)
    case undecodable(String, String)

    var description: String {
        switch self {
        case .missing(let path): "no such file: \(path)"
        case .undecodable(let name, let why): "cannot decode \(name): \(why)"
        }
    }
}
