import ComposeKit
import Foundation
import Subprocess

/// Runs the `container` CLI as an asynchronous subprocess.
///
/// ComposeKit drives the stable public `container` command line rather than the
/// internal XPC API. The executable is resolved from an explicit initializer
/// override, the `CONTAINER_CLI` environment variable, or `container` on
/// `PATH` — set an override to point at a different binary (or a test shim).
///
/// Set ``dryRun`` to print commands without executing them, and ``verbose`` to
/// trace each invocation to standard error.
public struct ContainerRunner: Sendable {
    /// When `true`, commands are traced but never executed; runs report success.
    public var dryRun: Bool
    /// When `true`, every command is echoed to standard error before running.
    public var verbose: Bool
    private let executable: String

    private static let captureLimit = 16 * 1024 * 1024

    /// Create a runner, resolving the executable from an explicit override,
    /// `CONTAINER_CLI`, or `container` on `PATH` (in that order).
    public init(
        dryRun: Bool = false, verbose: Bool = false, executable: String? = nil
    ) {
        self.dryRun = dryRun
        self.verbose = verbose
        self.executable = executable
            ?? ProcessInfo.processInfo.environment["CONTAINER_CLI"]
            ?? "container"
    }

    private func trace(_ args: [String]) {
        if verbose || dryRun {
            FileHandle.standardError.write(Data("+ \(executable) \(args.joined(separator: " "))\n".utf8))
        }
    }

    private var processOptions: PlatformOptions {
        var options = PlatformOptions()
        options.teardownSequence = [
            .gracefulShutDown(allowedDurationToNextStep: .seconds(1))
        ]
        return options
    }

    private func status(_ termination: TerminationStatus) -> Int32 {
        switch termination {
        case .exited(let code), .signaled(let code): return code
        }
    }

    /// Run asynchronously while inheriting stdio. Returns the exit status.
    @discardableResult
    public func run(_ args: [String]) async throws -> Int32 {
        trace(args)
        try Task.checkCancellation()
        if dryRun { return 0 }
        let result = try await Subprocess.run(
            .name(executable),
            arguments: Arguments(args),
            platformOptions: processOptions,
            input: .standardInput,
            output: .currentStandardOutput,
            error: .currentStandardError
        )
        try Task.checkCancellation()
        return status(result.terminationStatus)
    }

    /// Run a best-effort command asynchronously, discarding stdout/stderr.
    /// Used for idempotent cleanup (e.g. removing a possibly-absent container).
    /// Spawn failures are reported as `-1`; task cancellation is propagated.
    @discardableResult
    public func runSilently(_ args: [String]) async throws -> Int32 {
        trace(args)
        try Task.checkCancellation()
        if dryRun { return 0 }
        do {
            let result = try await Subprocess.run(
                .name(executable),
                arguments: Arguments(args),
                platformOptions: processOptions,
                input: .standardInput,
                output: .discarded,
                error: .discarded
            )
            try Task.checkCancellation()
            return status(result.terminationStatus)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return -1
        }
    }

    /// Run inheriting stdio, throwing ``RunnerError/nonZeroExit(command:status:)``
    /// if the command exits non-zero.
    public func runChecked(_ args: [String]) async throws {
        let status = try await run(args)
        if status != 0 {
            throw RunnerError.nonZeroExit(command: args, status: status)
        }
    }

    /// Run asynchronously and capture up to 16 MiB of stdout. stderr is inherited.
    public func capture(_ args: [String]) async throws -> (status: Int32, stdout: String) {
        trace(args)
        try Task.checkCancellation()
        if dryRun { return (0, "") }
        let result = try await Subprocess.run(
            .name(executable),
            arguments: Arguments(args),
            platformOptions: processOptions,
            input: .standardInput,
            output: .string(limit: Self.captureLimit),
            error: .currentStandardError
        )
        try Task.checkCancellation()
        return (status(result.terminationStatus), result.standardOutput ?? "")
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
