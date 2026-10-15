import Foundation
import Testing

import ComposeKit
@testable import ContainerComposeKit

@Suite("Container inventory decoding")
struct InventoryTests {
    static let listJSON = """
        [{"configuration":{"id":"demo-db","labels":{"com.apple.container.compose.project":"demo",
        "com.apple.container.compose.service":"db"},"mounts":[]},"id":"demo-db",
        "status":{"networks":[{"hostname":"demo-db","ipv4Address":"192.168.64.2\\/24",
        "ipv4Gateway":"192.168.64.1","network":"demo-default","variant":"reserved"}],
        "state":"running"}},
        {"configuration":{"id":"buildkit","labels":{}},"id":"buildkit","status":{"state":"stopped","networks":[]}}]
        """

    @Test("list output yields ids, labels, state and stripped addresses")
    func decodeList() throws {
        let records = try ContainerRecord.decodeList(Self.listJSON)
        #expect(records.map(\.id) == ["demo-db", "buildkit"])
        let db = records[0]
        #expect(db.project == "demo")
        #expect(db.service == "db")
        #expect(db.isRunning)
        #expect(db.networks.first?.ipv4 == "192.168.64.2")
        #expect(db.networks.first?.ipv4Gateway == "192.168.64.1")
        #expect(records[1].project == nil)
        #expect(!records[1].isRunning)
    }

    @Test("blank output (dry run) decodes to nothing; network inspect yields gateways")
    func blankAndNetworks() throws {
        #expect(try ContainerRecord.decodeList("  \n") == [])
        let networks = try NetworkRecord.decodeList(
            #"[{"id":"demo-default","configuration":{"mode":"nat"},"status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24"}}]"#
        )
        #expect(networks == [NetworkRecord(id: "demo-default", ipv4Gateway: "192.168.64.1")])
    }
}

@Suite("Hosts file rendering")
struct HostsRenderingTests {
    private let db = ProjectHosts.Peer(
        names: ["db", "demo-db"], aliases: ["demo-backend": ["postgres", "db"]],
        addresses: ["demo-backend": "10.5.0.2"])
    private let web = ProjectHosts.Peer(
        names: ["web", "demo-web"],
        addresses: ["demo-backend": "10.5.0.3", "demo-frontend": "192.168.64.3"])
    private let cache = ProjectHosts.Peer(names: ["cache"], addresses: ["demo-frontend": "192.168.64.4"])

    @Test("peers on shared networks, aliases deduped, gateway and extra_hosts")
    func render() {
        let text = ProjectHosts.render(
            networks: ["demo-backend"], peers: [web, db, cache], gateway: "10.5.0.1",
            extraHosts: ["api.local:1.2.3.4", "mac=host-gateway", "v6:[::1]"])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "127.0.0.1 localhost")
        #expect(lines[1] == "::1 localhost ip6-localhost ip6-loopback")
        #expect(lines.contains("10.5.0.2 db demo-db postgres"))
        #expect(lines.contains("10.5.0.3 web demo-web"))
        #expect(!text.contains("cache"))  // not on a shared network
        #expect(lines.contains("10.5.0.1 host.docker.internal gateway.docker.internal"))
        #expect(lines.contains("1.2.3.4 api.local"))
        #expect(lines.contains("10.5.0.1 mac"))
        #expect(lines.contains("::1 v6"))
        #expect(text.hasSuffix("\n"))
    }

    @Test("host entries are omitted when a DNS domain owns host.docker.internal or no gateway is known")
    func hostEntriesOmitted() {
        let viaDNS = ProjectHosts.render(
            networks: ["n"], peers: [], gateway: "10.0.0.1", extraHosts: ["x:host-gateway"],
            hostEntries: false)
        #expect(!viaDNS.contains("host.docker.internal"))
        #expect(viaDNS.contains("10.0.0.1 x"))
        let noGateway = ProjectHosts.render(networks: ["n"], peers: [], gateway: nil, extraHosts: ["x:host-gateway"])
        #expect(!noGateway.contains("host.docker.internal"))
        #expect(!noGateway.contains(" x"))
    }

    @Test("extra_hosts parsing accepts colon and equals, rejects malformed entries")
    func parseExtraHost() {
        let colon = ProjectHosts.parseExtraHost("a:1.1.1.1")
        #expect(colon?.host == "a" && colon?.address == "1.1.1.1")
        let equals = ProjectHosts.parseExtraHost("a = 2.2.2.2")
        #expect(equals?.host == "a" && equals?.address == "2.2.2.2")
        let v6 = ProjectHosts.parseExtraHost("a:[fe80::1]")
        #expect(v6?.host == "a" && v6?.address == "fe80::1")
        #expect(ProjectHosts.parseExtraHost("nonsense") == nil)
        #expect(ProjectHosts.parseExtraHost(":1.1.1.1") == nil)
    }

    @Test("writes rewrite the file in place, keeping its inode")
    func inPlaceWrite() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-hosts-\(UUID().uuidString)", isDirectory: true)
        let dir = projectDir.appendingPathComponent("hosts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let hosts = ProjectHosts(directory: dir)
        try hosts.write("127.0.0.1 localhost\n", for: "demo-web")
        let before = try FileManager.default.attributesOfItem(atPath: hosts.path(for: "demo-web"))
        try hosts.write("127.0.0.1 localhost\n10.0.0.2 db\n", for: "demo-web")
        let after = try FileManager.default.attributesOfItem(atPath: hosts.path(for: "demo-web"))
        #expect(before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64)
        #expect(try String(contentsOfFile: hosts.path(for: "demo-web"), encoding: .utf8).contains("10.0.0.2 db"))
        #expect(after[.size] as? Int == ProjectHosts.sizeQuantum)
        #expect(ProjectHosts.padded(Data(repeating: 65, count: 4097)).count == 2 * ProjectHosts.sizeQuantum)
        #expect(ProjectHosts.padded(Data(repeating: 65, count: 8192)).count == 8192)
        try hosts.remove()
        #expect(!FileManager.default.fileExists(atPath: projectDir.path))
    }

    @Test("the default state root avoids the temp dir and honors XDG_STATE_HOME")
    func defaultRoot() {
        #expect(ProjectHosts.defaultRoot(environment: ["XDG_STATE_HOME": "/x/state"]).path == "/x/state/container-compose")
        #expect(ProjectHosts.defaultRoot(environment: [:]).path.hasSuffix("/.local/state/container-compose"))
    }
}

@Suite("Service name resolution & orphans")
struct NameResolutionOrchestrationTests {
    /// A `container` shim that logs every call and answers `list`, `inspect`,
    /// `network inspect` and `system dns list` with canned JSON for project `proj`.
    private struct Harness {
        let dir: URL
        let log: URL
        let state: URL
        let runner: ContainerRunner

        init(tag: String) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cc-\(tag)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            log = dir.appendingPathComponent("commands.txt")
            state = dir.appendingPathComponent("state", isDirectory: true)
            let shim = dir.appendingPathComponent("container-shim")
            let labels = #""labels":{"com.apple.container.compose.project":"proj","com.apple.container.compose.service":"%s"}"#
            let record = """
                {"configuration":{\(labels)},"id":"%s","status":{"state":"running","networks":[{"network":"proj-default","ipv4Address":"%s/24","ipv4Gateway":"192.168.64.1"}]}}
                """
            let script = """
                #!/bin/sh
                printf '%s\\n' "$*" >> '\(log.path)'
                case "$1" in
                  list)
                    printf '[\(record),\(record),{"configuration":{\(labels)},"id":"proj-stale","status":{"state":"stopped","networks":[]}}]\\n' old proj-old 192.168.64.9 db proj-db 192.168.64.2 stale ;;
                  inspect)
                    case "$2" in
                      proj-db) printf '[\(record)]\\n' db proj-db 192.168.64.2 ;;
                      proj-app) printf '[\(record)]\\n' app proj-app 192.168.64.3 ;;
                    esac ;;
                  network) printf '[{"id":"proj-default","status":{"ipv4Gateway":"192.168.64.1"}}]\\n' ;;
                  system) printf '[]\\n' ;;
                esac
                exit 0
                """
            try script.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            runner = ContainerRunner(executable: shim.path)
        }

        func orchestrator(_ yaml: String) throws -> Orchestrator {
            let project = Project(
                name: "proj", file: try ComposeFile.parse(yaml: yaml),
                baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
            return Orchestrator(project: project, runner: runner, stateDirectory: state)
        }

        var commands: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func hostsFile(_ container: String) throws -> String {
            try String(contentsOfFile: state.appendingPathComponent("proj/hosts/\(container)").path, encoding: .utf8)
        }

        func tearDown() { try? FileManager.default.removeItem(at: dir) }
    }

    private let stack = """
        services:
          db:
            image: postgres:16
            networks:
              default:
                aliases: [postgres]
          app:
            image: app
            depends_on: [db]
            extra_hosts:
              - "mac:host-gateway"
              - "legacy.local:10.1.1.1"
        """

    @Test("up mounts a hosts file per service listing peers, host gateway and extra_hosts")
    func upWritesHosts() async throws {
        let h = try Harness(tag: "hosts")
        defer { h.tearDown() }
        try await h.orchestrator(stack).up(build: false, only: [])

        let appHosts = try h.hostsFile("proj-app")
        #expect(appHosts.contains("192.168.64.2 db proj-db postgres\n"))
        #expect(appHosts.contains("192.168.64.3 app proj-app\n"))
        #expect(appHosts.contains("192.168.64.1 host.docker.internal gateway.docker.internal\n"))
        #expect(appHosts.contains("192.168.64.1 mac\n"))
        #expect(appHosts.contains("10.1.1.1 legacy.local\n"))

        // db started first, but its file is refreshed once app is up.
        #expect(try h.hostsFile("proj-db").contains("192.168.64.3 app proj-app\n"))

        let mount = "--volume \(h.state.path)/proj/hosts/proj-app:/etc/hosts"
        #expect(h.commands.contains { $0.hasPrefix("run --detach --name proj-app") && $0.contains(mount) })
        #expect(h.commands.contains("inspect proj-db"))
        #expect(h.commands.contains("inspect proj-app"))
    }

    @Test("orphans are only warned about unless --remove-orphans is passed")
    func orphans() async throws {
        let keep = try Harness(tag: "orphan-keep")
        defer { keep.tearDown() }
        try await keep.orchestrator(stack).up(build: false, only: [])
        #expect(!keep.commands.contains("delete --force proj-old"))
        #expect(!keep.commands.contains("delete --force proj-stale"))

        let remove = try Harness(tag: "orphan-remove")
        defer { remove.tearDown() }
        try await remove.orchestrator(stack).up(build: false, only: [], removeOrphans: true)
        #expect(remove.commands.contains("stop proj-old"))
        #expect(remove.commands.contains("delete --force proj-old"))
        #expect(remove.commands.contains("delete --force proj-stale"))  // stopped orphans count too
    }

    @Test("down --remove-orphans removes orphans and the hosts files")
    func downOrphans() async throws {
        let h = try Harness(tag: "down")
        defer { h.tearDown() }
        let orch = try h.orchestrator(stack)
        try await orch.up(build: false, only: [])
        #expect(FileManager.default.fileExists(atPath: h.state.appendingPathComponent("proj/hosts").path))
        try await orch.down(removeVolumes: false, removeOrphans: true)
        #expect(h.commands.contains("delete --force proj-old"))
        #expect(!FileManager.default.fileExists(atPath: h.state.appendingPathComponent("proj/hosts").path))
    }

    @Test("start refreshes hosts files with the new addresses")
    func startRefreshes() async throws {
        let h = try Harness(tag: "start")
        defer { h.tearDown() }
        try await h.orchestrator(stack).start(only: [])
        #expect(h.commands.contains("start proj-db"))
        #expect(h.commands.contains("inspect proj-app"))
        #expect(try h.hostsFile("proj-db").contains("192.168.64.3 app proj-app\n"))
    }
}
