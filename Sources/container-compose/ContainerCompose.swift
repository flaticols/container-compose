//===----------------------------------------------------------------------===//
// container-compose — entry point.
//
// Invoked either standalone (`container-compose up`) or as a `container` CLI
// plugin (`container compose up`, which execs this binary).
//===----------------------------------------------------------------------===//

import ArgumentParser
import ComposeKit
import ContainerComposeKit
import Foundation

@main
struct ContainerCompose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run multi-container Compose applications with Apple's container.",
        version: containerComposeVersion,
        subcommands: [
            Up.self, Down.self, Ps.self, Logs.self, Config.self,
            Exec.self, Pull.self, Stop.self, Start.self, Restart.self,
            Update.self,
        ],
        defaultSubcommand: Up.self
    )
}

/// Options shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Path to the Compose file.")
    var file: String?

    @Option(name: [.customShort("p"), .long], help: "Project name (defaults to the directory name).")
    var projectName: String?

    @Option(name: .long, help: "Path to an env file for ${VAR} interpolation (default: .env).")
    var envFile: String?

    @Option(name: .long, help: "Enable a profile (repeatable; merged with COMPOSE_PROFILES).")
    var profile: [String] = []

    @Flag(name: .long, help: "Print the container commands without running them.")
    var dryRun = false

    // Long-only: `-v` is reserved for `down --volumes` (Docker-compatible).
    @Flag(name: .long, help: "Echo each container command as it runs.")
    var verbose = false

    func loadProject() throws -> Project {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try Project.load(
            explicit: file, projectName: projectName, cwd: cwd, envFile: envFile, profiles: profile)
    }

    /// Build a ready-to-use Orchestrator from these options.
    func makeOrchestrator() throws -> Orchestrator {
        let project = try loadProject()
        let runner = ContainerRunner(dryRun: dryRun, verbose: verbose)
        return Orchestrator(project: project, runner: runner)
    }
}
