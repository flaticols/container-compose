import Foundation
import Yams

public enum ComposeError: Error, CustomStringConvertible {
    case fileNotFound([String])
    case dependencyCycle(String)
    case serviceMissingImage(String)
    case unknownService(String)

    public var description: String {
        switch self {
        case .fileNotFound(let tried):
            return "no Compose file found (looked for: \(tried.joined(separator: ", ")))"
        case .dependencyCycle(let name):
            return "dependency cycle detected involving service '\(name)'"
        case .serviceMissingImage(let name):
            return "service '\(name)' has neither 'image' nor 'build'"
        case .unknownService(let name):
            return "no such service: '\(name)'"
        }
    }
}

/// A loaded Compose file plus the resolved project identity and base directory.
public struct Project: Sendable {
    public let name: String
    public let file: ComposeFile
    /// Directory of the Compose file — relative paths resolve against this.
    public let baseDirectory: URL

    public static let candidateFilenames = [
        "compose.yaml", "compose.yml",
        "docker-compose.yaml", "docker-compose.yml",
    ]

    /// Locate a Compose file: the explicit `-f` path, else the first candidate
    /// found walking up from `cwd`.
    public static func locate(explicit: String?, cwd: URL) throws -> URL {
        if let explicit {
            let url = URL(fileURLWithPath: explicit, relativeTo: cwd).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ComposeError.fileNotFound([explicit])
            }
            return url
        }
        var dir = cwd.standardizedFileURL
        while true {
            for candidate in candidateFilenames {
                let url = dir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // reached filesystem root
            dir = parent
        }
        throw ComposeError.fileNotFound(candidateFilenames)
    }

    public static func load(explicit: String?, projectName: String?, cwd: URL) throws -> Project {
        let url = try locate(explicit: explicit, cwd: cwd)
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let file = try ComposeFile.parse(yaml: yaml)
        let base = url.deletingLastPathComponent()
        let name = resolveName(override: projectName, file: file, composeURL: url)
        return Project(name: name, file: file, baseDirectory: base)
    }

    /// Project name precedence: `-p` flag > top-level `name:` > parent dir name.
    static func resolveName(override: String?, file: ComposeFile, composeURL: URL) -> String {
        if let override { return sanitize(override) }
        if let n = file.name { return sanitize(n) }
        return sanitize(composeURL.deletingLastPathComponent().lastPathComponent)
    }

    /// Lowercase; keep [a-z0-9_-]; collapse other runs to a single '-'.
    static func sanitize(_ raw: String) -> String {
        var out = ""
        var lastDash = false
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "compose" : trimmed
    }
}
