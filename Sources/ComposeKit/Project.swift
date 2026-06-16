import Foundation
import Yams

public enum ComposeError: Error, CustomStringConvertible {
    case fileNotFound([String])
    case dependencyCycle(String)
    case serviceMissingImage(String)
    case unknownService(String)
    case interpolation(String)
    case requiredVariable(String, String?)
    case envFileNotFound(String)
    case dependencyUnhealthy(String)

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
        case .interpolation(let message):
            return "interpolation error: \(message)"
        case .requiredVariable(let name, let message):
            let detail = (message?.isEmpty == false) ? ": \(message!)" : ""
            return "required variable '\(name)' is not set\(detail)"
        case .envFileNotFound(let path):
            return "env file not found: \(path)"
        case .dependencyUnhealthy(let name):
            return "dependency '\(name)' did not become healthy in time"
        }
    }
}

/// A loaded Compose file plus the resolved project identity and base directory.
public struct Project: Sendable {
    public let name: String
    public let file: ComposeFile
    /// Directory of the Compose file — relative paths resolve against this.
    public let baseDirectory: URL
    /// Variables used for `${VAR}` interpolation and `environment:` pass-through
    /// (`.env` merged with the shell environment, shell winning).
    public let variables: [String: String]

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

    public static func load(
        explicit: String?,
        projectName: String?,
        cwd: URL,
        envFile: String? = nil
    ) throws -> Project {
        let url = try locate(explicit: explicit, cwd: cwd)
        let base = url.deletingLastPathComponent()
        let variables = try loadVariables(envFile: envFile, baseDirectory: base, cwd: cwd)

        let rawYaml = try String(contentsOf: url, encoding: .utf8)
        let interpolated = try Interpolator.expand(rawYaml, variables: variables)
        let file = try ComposeFile.parse(yaml: interpolated)

        let name = resolveName(override: projectName, file: file, composeURL: url)
        return Project(name: name, file: file, baseDirectory: base, variables: variables)
    }

    /// `.env` (next to the Compose file, or the explicit `--env-file`) merged
    /// with the shell environment. The shell environment takes precedence.
    static func loadVariables(envFile: String?, baseDirectory: URL, cwd: URL) throws -> [String: String] {
        var variables: [String: String] = [:]
        if let envFile {
            let path = URL(fileURLWithPath: envFile, relativeTo: cwd).standardizedFileURL
            guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
                throw ComposeError.envFileNotFound(path.path)
            }
            variables = EnvFile.parse(contents)
        } else {
            let defaultEnv = baseDirectory.appendingPathComponent(".env")
            if let contents = try? String(contentsOf: defaultEnv, encoding: .utf8) {
                variables = EnvFile.parse(contents)
            }
        }
        for (key, value) in ProcessInfo.processInfo.environment {
            variables[key] = value
        }
        return variables
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
