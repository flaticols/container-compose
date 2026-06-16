//===----------------------------------------------------------------------===//
// Thin wrapper around the `container` CLI.
//
// Option A: we drive the stable public CLI rather than the internal XPC API.
// The executable is resolved from $CONTAINER_CLI, else `container` on PATH.
//===----------------------------------------------------------------------===//

import Foundation

public struct ContainerRunner: Sendable {
    public var dryRun: Bool
    public var verbose: Bool
    private let executable: String

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

    /// Run, throwing if the command exits non-zero.
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

    public enum RunnerError: Error, CustomStringConvertible {
        case nonZeroExit(command: [String], status: Int32)

        public var description: String {
            switch self {
            case .nonZeroExit(let command, let status):
                return "`container \(command.joined(separator: " "))` exited with status \(status)"
            }
        }
    }
}
