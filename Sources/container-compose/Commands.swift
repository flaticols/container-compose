//===----------------------------------------------------------------------===//
// Subcommands: up, down, ps, logs, config.
//===----------------------------------------------------------------------===//

import ArgumentParser
import ComposeKit
import ComposeKitContainer
import Foundation

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and start containers for the project.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Build images before starting (even if an image is present).")
    var build = false

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.up(build: build, only: services)
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop and remove containers, and project networks.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: [.customShort("v"), .long], help: "Also remove named volumes declared in the file.")
    var volumes = false

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.down(removeVolumes: volumes)
    }
}

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List containers for the project.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: [.short, .long], help: "Show stopped containers too.")
    var all = false

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.ps(all: all)
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show container logs.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: [.short, .long], help: "Follow log output.")
    var follow = false

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.logs(follow: follow, only: services)
    }
}

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in a running service container.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: [.customShort("i"), .long], help: "Keep stdin open (interactive).")
    var interactive = false

    @Flag(name: [.customShort("t"), .long], help: "Allocate a pseudo-TTY.")
    var tty = false

    @Argument(help: "Service whose container to exec into.")
    var service: String

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run.")
    var command: [String]

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        let status = try orchestrator.exec(
            service: service, command: command, interactive: interactive, tty: tty)
        if status != 0 { throw ExitCode(status) }
    }
}

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pull images for the project's services.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.pull(only: services)
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop service containers without removing them.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.stop(only: services)
    }
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start existing service containers without recreating them.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.start(only: services)
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart service containers (stop then start).")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Limit to these services (default: all).")
    var services: [String] = []

    func run() async throws {
        let orchestrator = try options.makeOrchestrator()
        try orchestrator.restart(only: services)
    }
}

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate and show the resolved project plan.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let project = try options.loadProject()
        // Mirror `up`: only services enabled by the active profiles (plus their
        // dependencies) are part of the plan, so the preview must not list
        // profile-gated services that `up` would skip.
        let enabled = project.enabledServices()
        let services = project.file.services.filter { enabled.contains($0.key) }
        let order = try Planner.startOrder(services)
        print("project:   \(project.name)")
        print("base dir:  \(project.baseDirectory.path)")
        if !project.activeProfiles.isEmpty {
            print("profiles:  \(project.activeProfiles.sorted().joined(separator: ", "))")
        }
        print("services:  \(services.keys.sorted().joined(separator: ", "))")
        print("start order:")
        for (i, name) in order.enumerated() {
            let deps = project.file.services[name]?.depends_on?.names ?? []
            let suffix = deps.isEmpty ? "" : "  (after: \(deps.sorted().joined(separator: ", ")))"
            print("  \(i + 1). \(name)\(suffix)")
        }
        if let networks = project.file.networks, !networks.isEmpty {
            print("networks:  \(networks.keys.sorted().joined(separator: ", "))")
        }
        if let volumes = project.file.volumes, !volumes.isEmpty {
            print("volumes:   \(volumes.keys.sorted().joined(separator: ", "))")
        }
    }
}
