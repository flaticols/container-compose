import Foundation
import Testing

@testable import ContainerComposeKit

@Suite("Container runner")
struct ContainerRunnerTests {
    @Test("capture returns status and stdout")
    func capture() async throws {
        let runner = ContainerRunner(executable: "/bin/sh")
        let result = try await runner.capture(["-c", "printf hello"])

        #expect(result.status == 0)
        #expect(result.stdout == "hello")
    }

    @Test("silent spawn failures return minus one")
    func spawnFailure() async throws {
        let runner = ContainerRunner(executable: "container-compose-missing-\(UUID().uuidString)")
        #expect(try await runner.runSilently([]) == -1)
    }

    @Test("cancelling a run terminates the child and throws cancellation")
    func cancellation() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-runner-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let runner = ContainerRunner(executable: "/bin/sh")
        let task = Task {
            try await runner.runSilently(["-c", "echo started > '\(marker.path)'; exec sleep 30"])
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
