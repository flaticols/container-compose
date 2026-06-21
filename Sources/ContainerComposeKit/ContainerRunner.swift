import ComposeKit
import Foundation

/// Runs the `container` CLI as a subprocess.
///
/// ComposeKit drives the stable public `container` command line rather than the
/// internal XPC API. The executable is resolved from the `CONTAINER_CLI`
/// environment variable, falling back to `container` on `PATH` — set
/// `CONTAINER_CLI` to point at a different binary (or a test shim).
///
/// Set ``dryRun`` to print commands without executing them, and ``verbose`` to
/// trace each invocation to standard error.
public struct ContainerRunner: Sendable {
    /// When `true`, commands are traced but never executed; runs report success.
    public var dryRun: Bool
    /// When `true`, every command is echoed to standard error before running.
    public var verbose: Bool
    private let executable: String

    /// Create a runner, resolving the executable from `CONTAINER_CLI` (or
    /// `container` on `PATH`).
    public init(dryRun: Bool = false, verbose: Bool = false) {
        self.dryRun = dryRun
        self.verbose = verbose
        self.executable = ProcessInfo.processInfo.environment["CONTAINER_CLI"] ?? "container"
    }

    private func trace(_ args: [String]) {
        if verbose || dryRun {
            FileHandle.standardError.write(Data("+ \(executable) \(args.joined(separator: " "))\n".utf8))
        }
    }

    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        // Resolve via env so PATH is honored without hardcoding /usr/local/bin.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + args
        return p
    }

    /// Run inheriting stdio. Returns the exit status.
    @discardableResult
    public func run(_ args: [String]) throws -> Int32 {
        trace(args)
        if dryRun { return 0 }
        let p = makeProcess(args)
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Run a best-effort command, discarding stdout/stderr and never throwing.
    /// Used for idempotent cleanup (e.g. removing a possibly-absent container).
    @discardableResult
    public func runSilently(_ args: [String]) -> Int32 {
        trace(args)
        if dryRun { return 0 }
        let p = makeProcess(args)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Run inheriting stdio, throwing ``RunnerError/nonZeroExit(command:status:)``
    /// if the command exits non-zero.
    public func runChecked(_ args: [String]) throws {
        let status = try run(args)
        if status != 0 {
            throw RunnerError.nonZeroExit(command: args, status: status)
        }
    }

    /// Run and capture stdout. stderr is inherited.
    public func capture(_ args: [String]) throws -> (status: Int32, stdout: String) {
        trace(args)
        if dryRun { return (0, "") }
        let p = makeProcess(args)
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Errors thrown by ``runChecked(_:)``.
    public enum RunnerError: Error, CustomStringConvertible {
        /// A command exited with a non-zero status.
        case nonZeroExit(command: [String], status: Int32)

        public var description: String {
            switch self {
            case .nonZeroExit(let command, let status):
                return "`container \(command.joined(separator: " "))` exited with status \(status)"
            }
        }
    }
}
