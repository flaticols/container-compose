import Foundation
import Testing

import ComposeKit
@testable import ContainerComposeKit

@Suite("Concurrent health gating")
struct OrchestratorConcurrencyTests {
    @Test("up --wait checks independent services concurrently")
    func waitChecksConcurrently() async throws {
        try await withShim { runner, directory in
            let barrier = barrierScript(directory: directory, containers: ["p-a", "p-b"])
            try writeShim(barrier, to: runner.shim)

            let project = try makeProject(
                """
                services:
                  a:
                    image: x
                    healthcheck:
                      test: ["CMD", "true"]
                      retries: 1
                  b:
                    image: x
                    healthcheck:
                      test: ["CMD", "true"]
                      retries: 1
                """)
            let orchestrator = Orchestrator(
                project: project, runner: ContainerRunner(executable: runner.shim.path), stateDirectory: testStateDirectory)

            try await orchestrator.up(build: false, only: [], wait: true)
        }
    }

    @Test("multiple healthy dependencies are gated concurrently")
    func dependencyChecksConcurrently() async throws {
        try await withShim { runner, directory in
            let barrier = barrierScript(directory: directory, containers: ["p-a", "p-b"])
            try writeShim(barrier, to: runner.shim)

            let project = try makeProject(
                """
                services:
                  a:
                    image: x
                    healthcheck:
                      test: ["CMD", "true"]
                      retries: 1
                  b:
                    image: x
                    healthcheck:
                      test: ["CMD", "true"]
                      retries: 1
                  app:
                    image: x
                    depends_on:
                      a:
                        condition: service_healthy
                      b:
                        condition: service_healthy
                """)
            let orchestrator = Orchestrator(
                project: project, runner: ContainerRunner(executable: runner.shim.path), stateDirectory: testStateDirectory)

            try await orchestrator.up(build: false, only: [], wait: false)
        }
    }

    @Test("a dependency that passed a health gate is not polled again")
    func successfulGateIsCached() async throws {
        try await withShim { runner, _ in
            let script = """
                #!/bin/sh
                if [ "$1" = "exec" ]; then
                  printf '%s\\n' "$*" >> '\(runner.log.path)'
                fi
                exit 0
                """
            try writeShim(script, to: runner.shim)

            let project = try makeProject(
                """
                services:
                  db:
                    image: x
                    healthcheck:
                      test: ["CMD", "true"]
                      retries: 1
                  app1:
                    image: x
                    depends_on:
                      db:
                        condition: service_healthy
                  app2:
                    image: x
                    depends_on:
                      db:
                        condition: service_healthy
                """)
            let orchestrator = Orchestrator(
                project: project, runner: ContainerRunner(executable: runner.shim.path), stateDirectory: testStateDirectory)

            try await orchestrator.up(build: false, only: [], wait: false)

            let log = (try? String(contentsOf: runner.log, encoding: .utf8)) ?? ""
            let checks = log.split(separator: "\n").filter { $0.hasPrefix("exec p-db ") }
            #expect(checks.count == 1)
        }
    }

    private struct ShimFiles {
        let shim: URL
        let log: URL
    }

    private func withShim(
        _ operation: (ShimFiles, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orchestrator-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await operation(
            ShimFiles(
                shim: directory.appendingPathComponent("container-shim"),
                log: directory.appendingPathComponent("commands.txt")),
            directory)
    }

    private func writeShim(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func barrierScript(directory: URL, containers: [String]) -> String {
        let conditions = containers
            .map { "[ -f '\(directory.path)/\($0)' ]" }
            .joined(separator: " && ")
        return """
            #!/bin/sh
            if [ "$1" = "exec" ]; then
              touch '\(directory.path)/'"$2"
              attempts=0
              while [ "$attempts" -lt 100 ]; do
                if \(conditions); then
                  exit 0
                fi
                sleep 0.01
                attempts=$((attempts + 1))
              done
              exit 1
            fi
            exit 0
            """
    }

    private func makeProject(_ yaml: String) throws -> Project {
        Project(
            name: "p", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
    }
}
