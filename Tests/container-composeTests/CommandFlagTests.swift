import ArgumentParser
import Testing

@testable import container_compose

@Suite("Docker-compatible flags")
struct CommandFlagTests {
    @Test("up accepts -d/--detach and --remove-orphans")
    func upFlags() throws {
        let short = try Up.parse(["-d", "web"])
        #expect(short.detach)
        #expect(short.services == ["web"])
        let long = try Up.parse(["--detach", "--remove-orphans"])
        #expect(long.detach)
        #expect(long.removeOrphans)
        #expect(!(try Up.parse([])).removeOrphans)
    }

    @Test("down accepts --remove-orphans alongside -v")
    func downFlags() throws {
        let down = try Down.parse(["-v", "--remove-orphans"])
        #expect(down.volumes)
        #expect(down.removeOrphans)
    }
}
