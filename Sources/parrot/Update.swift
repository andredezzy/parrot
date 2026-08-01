import ArgumentParser
import Foundation

/// Replaces the running binary with the newest GitHub release.
///
/// The signing step is the reason this can exist at all. macOS anchors an
/// Accessibility grant to the binary's cdhash unless the signature carries a
/// certificate, so an unsigned update silently costs the user their hotkey and
/// a trip through System Settings. Re-signing the download with the same local
/// identity keeps the designated requirement identical, and the grant with it.
struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update to the latest release."
    )

    @Flag(name: .long, help: "Report whether an update exists and stop.")
    var check = false

    func run() throws {
        guard let latest = try Release.latest() else {
            print("could not reach GitHub; try again later")
            throw ExitCode(1)
        }
        guard latest.tag != "v\(parrotVersion)" else {
            print("already on \(latest.tag)")
            return
        }
        print("\(latest.tag) available (running v\(parrotVersion))")
        if check { return }

        let staged = try Release.download(latest)
        let identity = Signing.localIdentity()
        if let identity {
            try Signing.sign(staged, as: identity)
        } else {
            print("no local signing identity, so macOS will ask for Accessibility again")
            print("scripts/install-local.sh explains how to create one once")
        }
        try Installed.replace(with: staged)
        Installed.restartDaemon()
        print("updated to \(latest.tag)")
    }
}

enum Release {
    static let repo = "andredezzy/parrot"
    static let asset = "parrot-macos-arm64.tar.gz"

    struct Latest {
        let tag: String
        var assetURL: URL {
            URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(asset)")!
        }
    }

    /// Nil when GitHub is unreachable, which is a reason to say nothing rather
    /// than a reason to fail: a daemon that cannot check for updates still works.
    static func latest() throws -> Latest? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("parrot/\(parrotVersion)", forHTTPHeaderField: "User-Agent")

        var payload: Data?
        let waiter = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            payload = data
            waiter.signal()
        }.resume()
        guard waiter.wait(timeout: .now() + 15) == .success, let payload else { return nil }

        struct Body: Decodable { let tag_name: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: payload) else { return nil }
        return Latest(tag: body.tag_name)
    }

    /// Downloads and unpacks into a temporary directory, and refuses anything
    /// that will not run: a broken download must not replace a working binary.
    static func download(_ latest: Latest) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "parrot-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appending(path: asset)

        print("downloading \(latest.tag)...")
        let data = try Data(contentsOf: latest.assetURL)
        try data.write(to: archive)
        try shell("/usr/bin/tar", ["-xzf", archive.path(percentEncoded: false),
                                 "-C", directory.path(percentEncoded: false)])

        let binary = directory.appending(path: "parrot")
        guard FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)) else {
            throw UpdateError.archiveHadNoBinary
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: binary.path(percentEncoded: false))
        _ = try? shell("/usr/bin/xattr", ["-d", "com.apple.quarantine",
                                        binary.path(percentEncoded: false)])
        // `--help` rather than `--version`: every release parses it, including
        // the ones published before this command existed. It proves the binary
        // loads, links and runs, which is all a smoke test owes us here.
        guard (try? shell(binary.path(percentEncoded: false), ["--help"])) != nil else {
            throw UpdateError.downloadWillNotRun
        }
        return binary
    }
}

enum Signing {
    static let identityName = "Parrot Local Signing"

    static func localIdentity() -> String? {
        guard let listed = try? shell("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]),
              listed.contains(identityName)
        else { return nil }
        return identityName
    }

    /// Signs with `--identifier parrot` so the designated requirement matches
    /// the one the running binary was granted under.
    static func sign(_ binary: URL, as identity: String) throws {
        _ = try shell("/usr/bin/codesign", ["-f", "-s", identity, "--identifier", "parrot",
                                          binary.path(percentEncoded: false)])
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case archiveHadNoBinary
    case downloadWillNotRun
    case cannotWriteBinary(String)

    var description: String {
        switch self {
        case .archiveHadNoBinary: "the release archive did not contain parrot"
        case .downloadWillNotRun: "the downloaded binary did not run, so it was not installed"
        case .cannotWriteBinary(let path): "cannot write \(path); try again with sudo"
        }
    }
}

/// The binary this daemon is running as, and how to put a new one in its place.
enum Installed {
    /// Whatever binary is running, rather than a fixed location: parrot updates
    /// itself where it was installed, and a copy under /tmp updates that copy.
    static var path: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Overwrites in place rather than moving a file over the target: the
    /// LaunchAgent, the Accessibility grant and anything else holding this path
    /// keep pointing at the same inode.
    static func replace(with staged: URL) throws {
        guard FileManager.default.isWritableFile(atPath: path) else {
            throw UpdateError.cannotWriteBinary(path)
        }
        try Data(contentsOf: staged).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// A no-op when the daemon is not registered, which is how anyone running
    /// parrot from a terminal uses it.
    ///
    /// `kickstart -k` rather than bootout followed by bootstrap. The update runs
    /// inside the daemon, so a bootout kills the process that still has to issue
    /// the bootstrap: the service goes away and never comes back. kickstart is
    /// one call that launchd carries out on its own, and it does not care that
    /// the caller dies partway through.
    static func restartDaemon() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appending(path: "Library/LaunchAgents/\(Install.label).plist")
        guard FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)) else { return }
        _ = try? shell("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Install.label)"])
    }
}

@discardableResult
func shell(_ launchPath: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UpdateError.downloadWillNotRun
    }
    return String(decoding: output, as: UTF8.self)
}
