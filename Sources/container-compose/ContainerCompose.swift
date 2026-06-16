//===----------------------------------------------------------------------===//
// container-compose — entry point.
//
// Invoked either standalone (`container-compose up`) or as a `container` CLI
// plugin (`container compose up`, which execs this binary).
//===----------------------------------------------------------------------===//

import ArgumentParser
import ComposeKit
import Foundation

@main
struct ContainerCompose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run multi-container Compose applications with Apple's container.",
        version: "0.1.0",
        subcommands: [Up.self, Down.self, Ps.self, Logs.self, Config.self],
        defaultSubcommand: Up.self
    )
}

/// Options shared by every subcommand.
struct GlobalOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Path to the Compose file.")
    var file: String?

    @Option(name: [.customShort("p"), .long], help: "Project name (defaults to the directory name).")
    var projectName: String?

    @Flag(name: .long, help: "Print the container commands without running them.")
    var dryRun = false

    @Flag(name: [.short, .long], help: "Echo each container command as it runs.")
    var verbose = false

    /// Build a ready-to-use Orchestrator from these options.
    func makeOrchestrator() throws -> Orchestrator {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let project = try Project.load(explicit: file, projectName: projectName, cwd: cwd)
        let runner = ContainerRunner(dryRun: dryRun, verbose: verbose)
        return Orchestrator(project: project, runner: runner)
    }
}
