// `container-compose update` — self-update from the latest GitHub Release.
//
// Checks the Releases API, downloads the signed + notarized .pkg, verifies its
// signature, and installs it (the macOS installer places the plugin in the right
// location and prompts for admin). Works regardless of how it was installed.

import ArgumentParser
import Foundation

private let repoSlug = "flaticols/container-compose"

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update container-compose to the latest release."
    )

    @Flag(name: .long, help: "Only check for a newer version; don't download or install.")
    var check = false

    @Flag(name: .long, help: "Install even if it appears up to date (or a dev build).")
    var force = false

    func run() async throws {
        let current = containerComposeVersion
        let release = try await fetchLatestRelease()
        let latestTag = release.tag_name

        let currentV = SemVer(current)
        let latestV = SemVer(latestTag)
        let isNewer = (currentV != nil && latestV != nil) ? currentV! < latestV! : true

        guard isNewer || force else {
            print("container-compose is up to date (\(current)).")
            return
        }

        print("Current: \(current)   Latest: \(latestTag)")
        if check {
            print("Run `container-compose update` to install.")
            return
        }

        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }),
            let assetURL = URL(string: asset.browser_download_url)
        else {
            throw Fail("the latest release has no .pkg installer attached")
        }

        let pkg = try await download(asset.name, from: assetURL)
        defer { try? FileManager.default.removeItem(at: pkg) }

        try verifySignature(of: pkg)
        try install(pkg)
        print("Updated to \(latestTag). Run `container-compose --version` to confirm.")
    }

    // MARK: - Steps

    private func fetchLatestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("container-compose", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Fail("could not reach the GitHub Releases API (HTTP \(code))")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func download(_ name: String, from url: URL) async throws -> URL {
        print("Downloading \(name) ...")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Fail("download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest)
        return dest
    }

    private func verifySignature(of pkg: URL) throws {
        // A signed, notarized .pkg makes `pkgutil --check-signature` exit 0.
        let (status, _) = capture("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
        guard status == 0 else {
            throw Fail("the downloaded .pkg is not signed/notarized; refusing to install")
        }
        print("Signature verified.")
    }

    private func install(_ pkg: URL) throws {
        // Installing into /usr/local needs admin; `sudo installer` prompts in the
        // terminal and places the plugin where `container` looks for it.
        print("Installing (you may be prompted for your password) ...")
        let status = runInheriting(
            "/usr/bin/sudo", ["/usr/sbin/installer", "-pkg", pkg.path, "-target", "/"])
        guard status == 0 else { throw Fail("installer exited with status \(status)") }
    }
}

// MARK: - GitHub API model

private struct Release: Decodable {
    let tag_name: String
    let assets: [Asset]
}

private struct Asset: Decodable {
    let name: String
    let browser_download_url: String
}

// MARK: - Version comparison

/// A minimal semantic version: `major.minor.patch`, with a prerelease suffix
/// (e.g. `-dev`, `-beta1`) sorting before the same release.
struct SemVer: Comparable {
    let parts: [Int]
    let isPrerelease: Bool

    init?(_ raw: String) {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        let split = s.split(separator: "-", maxSplits: 1)
        isPrerelease = split.count > 1
        let nums = String(split[0]).split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        var p = nums.compactMap { $0 }
        while p.count < 3 { p.append(0) }
        parts = Array(p.prefix(3))
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        for i in 0..<3 where lhs.parts[i] != rhs.parts[i] { return lhs.parts[i] < rhs.parts[i] }
        // Same x.y.z: a prerelease precedes the final release.
        if lhs.isPrerelease != rhs.isPrerelease { return lhs.isPrerelease }
        return false
    }
}

// MARK: - Process helpers

private struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private func runInheriting(_ launchPath: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

private func capture(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
