import Foundation
import Testing

import ComposeKit
@testable import ContainerComposeKit

private func loadFixture() throws -> Project {
    let url = Bundle.module.url(forResource: "compose", withExtension: "yaml", subdirectory: "Fixtures")!
    let dir = url.deletingLastPathComponent()
    return try Project.load(explicit: url.path, projectName: nil, cwd: dir)
}

@Suite("Translation")
struct TranslationTests {
    private func translator() -> ContainerTranslator {
        ContainerTranslator(project: "demo", baseDirectory: URL(fileURLWithPath: "/proj"), hostEnv: [:])
    }

    @Test("run args carry name, labels, network, ports")
    func runArgs() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        let args = translator().runArgs(service: "web", web, image: "demo-web:latest")
        #expect(args.contains("run"))
        #expect(args.contains("--detach"))
        #expect(adjacent(args, "--name", "demo-web"))
        #expect(adjacent(args, "--publish", "8080:80"))
        #expect(adjacent(args, "--network", "demo-backend"))
        #expect(adjacent(args, "--network", "demo-frontend"))
        #expect(adjacent(args, "--cpus", "1"))  // fractional 0.5 -> 1 vCPU
        #expect(adjacent(args, "--memory", "256m"))
        // image precedes the command
        let imageIdx = args.firstIndex(of: "demo-web:latest")!
        let nodeIdx = args.firstIndex(of: "node")!
        #expect(imageIdx < nodeIdx)
    }

    @Test("named volume source is project-scoped, bind path is resolved")
    func volumes() throws {
        let project = try loadFixture()
        let db = project.file.services["db"]!
        let args = translator().runArgs(service: "db", db, image: "postgres:16")
        #expect(adjacent(args, "--volume", "demo-dbdata:/var/lib/postgresql/data"))

        let web = project.file.services["web"]!
        let webArgs = translator().runArgs(service: "web", web, image: "demo-web:latest")
        #expect(webArgs.contains { $0.hasSuffix("/proj/web/static:/app/static:ro") })
    }

    @Test("short string command runs through a shell")
    func shellCommand() throws {
        let yaml = """
            services:
              x:
                image: alpine
                command: echo hello
            """
        let file = try ComposeFile.parse(yaml: yaml)
        let args = translator().runArgs(service: "x", file.services["x"]!, image: "alpine")
        #expect(adjacent(args, "/bin/sh", "-c"))
        #expect(args.last == "echo hello")
    }

    @Test("fractional cpus are rounded up to whole vCPUs for container --cpus")
    func cpuCount() {
        #expect(ContainerTranslator.cpuCount("0.5") == "1")
        #expect(ContainerTranslator.cpuCount("1.5") == "2")
        #expect(ContainerTranslator.cpuCount("2") == "2")
        #expect(ContainerTranslator.cpuCount("4") == "4")
        #expect(ContainerTranslator.cpuCount("0") == nil)
        #expect(ContainerTranslator.cpuCount("abc") == nil)
    }
}

@Suite("Health")
struct HealthTests {
    @Test("duration parsing")
    func durations() {
        #expect(HealthChecker.seconds("30s") == 30)
        #expect(HealthChecker.seconds("1m30s") == 90)
        #expect(HealthChecker.seconds("500ms") == 0.5)
        #expect(HealthChecker.seconds("2") == 2)
        #expect(HealthChecker.seconds(nil) == nil)
    }

    @Test("test translation: CMD, CMD-SHELL, NONE, string")
    func translation() {
        #expect(HealthChecker.execArguments(for: .list(["CMD", "curl", "-f", "x"])) == ["curl", "-f", "x"])
        #expect(HealthChecker.execArguments(for: .list(["CMD-SHELL", "curl -f x"])) == ["/bin/sh", "-c", "curl -f x"])
        #expect(HealthChecker.execArguments(for: .list(["NONE"])) == nil)
        #expect(HealthChecker.execArguments(for: .string("pg_isready")) == ["/bin/sh", "-c", "pg_isready"])
    }

    @Test("depends_on condition is read")
    func condition() throws {
        let yaml = """
            services:
              web:
                image: x
                depends_on:
                  db:
                    condition: service_healthy
              db:
                image: y
            """
        let file = try ComposeFile.parse(yaml: yaml)
        #expect(file.services["web"]?.depends_on?.condition(for: "db") == "service_healthy")
    }
}

@Suite("New-field translation")
struct NewFieldTests {
    private func worker() throws -> Service {
        let url = Bundle.module.url(
            forResource: "resources", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8))
            .services["worker"]!
    }

    @Test("ulimits, shm_size, dns, runtime, tty translate to container flags")
    func translates() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let args = t.runArgs(service: "worker", try worker(), image: "app:latest")
        #expect(adjacent(args, "--ulimit", "nofile=1024:524288"))
        #expect(adjacent(args, "--ulimit", "nproc=65535"))
        #expect(adjacent(args, "--shm-size", "128m"))
        #expect(adjacent(args, "--runtime", "runc"))
        #expect(adjacent(args, "--dns-search", "corp.example.com"))
        #expect(adjacent(args, "--dns-option", "timeout:2"))
        #expect(args.contains("--interactive"))
        #expect(args.contains("--tty"))
    }

    @Test("extra_hosts normalizes list and map forms to host:ip")
    func extraHosts() {
        #expect(ExtraHosts.list(["a:1.1.1.1"]).entries == ["a:1.1.1.1"])
        #expect(
            ExtraHosts.map(["b": ComposeScalar("2.2.2.2"), "a": ComposeScalar("1.1.1.1")]).entries
                == ["a:1.1.1.1", "b:2.2.2.2"])
    }
}

@Suite("Configs & secrets")
struct FileObjectTests {
    private func appService() throws -> Service {
        let url = Bundle.module.url(
            forResource: "configs-secrets", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        return try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8)).services["app"]!
    }

    @Test("short and long refs parse")
    func parseRefs() throws {
        let app = try appService()
        #expect(app.secrets?.map(\.source).sorted() == ["api_key", "db_password"])
        #expect(app.configs?.map(\.source).sorted() == ["app_config", "nginx_conf"])
    }

    @Test("configs/secrets become read-only bind mounts at the right targets")
    func mounts() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let files = ContainerTranslator.ResolvedFileObjects(
            configs: ["app_config": "/h/app.yaml", "nginx_conf": "/h/nginx.conf"],
            secrets: ["db_password": "/h/db", "api_key": "/h/api"])
        let args = t.runArgs(service: "app", try appService(), image: "app:latest", files: files)
        #expect(adjacent(args, "--volume", "/h/db:/run/secrets/db_password:ro"))  // short secret default
        #expect(adjacent(args, "--volume", "/h/api:/etc/api/key:ro"))  // long secret custom target
        #expect(adjacent(args, "--volume", "/h/app.yaml:/etc/app/config.yaml:ro"))  // long config target
        #expect(adjacent(args, "--volume", "/h/nginx.conf:/nginx_conf:ro"))  // short config -> /name
        // Mounts precede the image.
        let vol = args.firstIndex(of: "/h/db:/run/secrets/db_password:ro")!
        #expect(vol < args.firstIndex(of: "app:latest")!)
    }

    @Test("detach:false omits --detach for one-shot runs")
    func detachFlag() throws {
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let svc = try ComposeFile.parse(yaml: "services:\n  x:\n    image: a\n").services["x"]!
        #expect(!t.runArgs(service: "x", svc, image: "a", detach: false).contains("--detach"))
        #expect(t.runArgs(service: "x", svc, image: "a").contains("--detach"))
    }
}

// .serialized: these mutate the process-global CONTAINER_CLI env var.

@Suite("Completed-successfully gating", .serialized)
struct OneShotTests {
    @Test("dry-run up completes for a stack using service_completed_successfully")
    func dryRunUp() throws {
        // local-dev.yaml gates web on migrate (service_completed_successfully);
        // a dry run exercises the one-shot detection + attached-run branch.
        let url = Bundle.module.url(
            forResource: "local-dev", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        let project = try Project.load(
            explicit: url.path, projectName: nil, cwd: url.deletingLastPathComponent())
        let orch = Orchestrator(project: project, runner: ContainerRunner(dryRun: true))
        try orch.up(build: false, only: [])
    }

    @Test("a failing one-shot dependency aborts up")
    func failingOneShotAborts() throws {
        // Shim `container` that always exits non-zero; the one-shot `a` then
        // fails and `up` must throw dependencyFailed before `b` is created.
        let shim = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-fail-shim-\(getpid())")
        try "#!/bin/sh\nexit 7\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        defer { try? FileManager.default.removeItem(at: shim) }

        setenv("CONTAINER_CLI", shim.path, 1)
        let runner = ContainerRunner()  // captures the shim path at init
        unsetenv("CONTAINER_CLI")

        let yaml = """
            services:
              a:
                image: alpine
                command: ["false"]
              b:
                image: alpine
                depends_on:
                  a:
                    condition: service_completed_successfully
            """
        let project = Project(
            name: "t", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
        let orch = Orchestrator(project: project, runner: runner)

        do {
            try orch.up(build: false, only: [])
            Issue.record("expected up to throw dependencyFailed")
        } catch let ComposeError.dependencyFailed(name, status) {
            #expect(name == "a")
            #expect(status == 7)
        }
    }
}

@Suite("Build translation")
struct BuildTests {
    @Test("advanced build fields translate to container build flags")
    func buildArgs() throws {
        let url = Bundle.module.url(
            forResource: "build-advanced", withExtension: "yaml", subdirectory: "Fixtures/corpus")!
        let svc = try ComposeFile.parse(yaml: String(contentsOf: url, encoding: .utf8))
            .services["app"]!
        let t = ContainerTranslator(
            project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
        let args = t.buildArgs(service: "app", svc, resolvedSecrets: ["build_token": "/h/tok"])!
        #expect(args.contains("--no-cache"))
        #expect(adjacent(args, "--label", "com.example.tier=web"))
        #expect(adjacent(args, "--secret", "id=build_token,src=/h/tok"))
    }
}

// .serialized: mutates the process-global CONTAINER_CLI env var.

@Suite("Lifecycle commands", .serialized)
struct LifecycleTests {
    /// Run `body` against an Orchestrator whose `container` is a shim that records
    /// each invocation, and return the recorded command lines.
    private func capture(_ tag: String, _ body: (Orchestrator) throws -> Void) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
        let log = dir.appendingPathComponent("ck-log-\(tag)-\(getpid()).txt")
        let shim = dir.appendingPathComponent("ck-shim-\(tag)-\(getpid()).sh")
        try? FileManager.default.removeItem(at: log)
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        defer {
            try? FileManager.default.removeItem(at: shim)
            try? FileManager.default.removeItem(at: log)
        }

        setenv("CONTAINER_CLI", shim.path, 1)
        let runner = ContainerRunner()  // captures the shim path at init
        unsetenv("CONTAINER_CLI")

        let yaml = """
            services:
              db:
                image: postgres:16
              app:
                build: .
                depends_on: [db]
            """
        let project = Project(
            name: "proj", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
        try body(Orchestrator(project: project, runner: runner))
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    @Test("exec passes -i/-t and the command into the service container")
    func exec() throws {
        let lines = try capture("exec") {
            _ = try $0.exec(service: "db", command: ["psql", "-U", "app"], interactive: true, tty: true)
        }
        #expect(lines.contains("exec --interactive --tty proj-db psql -U app"))
    }

    @Test("pull fetches image services and skips build-only ones")
    func pull() throws {
        let lines = try capture("pull") { try $0.pull(only: []) }
        #expect(lines.contains("image pull postgres:16"))
        #expect(!lines.contains { $0.contains("proj-app") })  // app builds locally
    }

    @Test("stop runs in reverse dependency order")
    func stop() throws {
        let lines = try capture("stop") { try $0.stop(only: []) }
        let app = lines.firstIndex(of: "stop proj-app")
        let db = lines.firstIndex(of: "stop proj-db")
        #expect(app != nil && db != nil && app! < db!)  // dependent stops first
    }

    @Test("restart stops everything before starting anything")
    func restart() throws {
        let lines = try capture("restart") { try $0.restart(only: []) }
        #expect(lines.contains("stop proj-db"))
        #expect(lines.contains("start proj-db"))
        let lastStop = lines.lastIndex { $0.hasPrefix("stop ") }!
        let firstStart = lines.firstIndex { $0.hasPrefix("start ") }!
        #expect(lastStop < firstStart)
    }

    @Test("down stops in reverse order, removes the network, keeps volumes")
    func down() throws {
        let lines = try capture("down") { try $0.down(removeVolumes: false) }
        let app = lines.firstIndex { $0.hasPrefix("stop proj-app") }
        let db = lines.firstIndex { $0.hasPrefix("stop proj-db") }
        #expect(app != nil && db != nil && app! < db!)  // dependent stops first
        #expect(lines.contains("network delete proj-default"))
        #expect(!lines.contains { $0.hasPrefix("volume delete") })
    }
}

@Suite("Port publishing")
struct PortPublishTests {
    private func translator() -> ContainerTranslator {
        ContainerTranslator(project: "p", baseDirectory: URL(fileURLWithPath: "/p"), hostEnv: [:])
    }
    private func service(_ ports: String) throws -> Service {
        try ComposeFile.parse(yaml: "services:\n  s:\n    image: x\n    ports:\n\(ports)").services["s"]!
    }

    @Test("a bare container port is not published (container can't auto-assign)")
    func barePort() throws {
        let args = translator().runArgs(service: "s", try service("      - \"80\"\n"), image: "x")
        #expect(!args.contains("--publish"))
    }

    @Test("a host:container port is published verbatim")
    func hostPort() throws {
        let args = translator().runArgs(service: "s", try service("      - \"8080:80\"\n"), image: "x")
        #expect(adjacent(args, "--publish", "8080:80"))
    }

    @Test("an IPv6 host_ip is bracketed")
    func ipv6() throws {
        let svc = try service("      - host_ip: \"::1\"\n        published: 8080\n        target: 80\n")
        #expect(adjacent(translator().runArgs(service: "s", svc, image: "x"), "--publish", "[::1]:8080:80"))
    }
}

@Suite("Orchestrator error paths")
struct OrchestratorErrorTests {
    private func project(_ yaml: String) throws -> Project {
        Project(
            name: "p", file: try ComposeFile.parse(yaml: yaml),
            baseDirectory: URL(fileURLWithPath: "/tmp"), variables: [:])
    }

    @Test("up on a service with neither image nor build throws serviceMissingImage")
    func missingImage() throws {
        let orch = Orchestrator(
            project: try project("services:\n  x: {}\n"), runner: ContainerRunner(dryRun: true))
        #expect(throws: ComposeError.self) { try orch.up(build: false, only: []) }
    }

    @Test("exec on an unknown service throws unknownService")
    func unknownExec() throws {
        let orch = Orchestrator(
            project: try project("services:\n  a:\n    image: x\n"),
            runner: ContainerRunner(dryRun: true))
        #expect(throws: ComposeError.self) { _ = try orch.exec(service: "nope", command: ["sh"]) }
    }
}

/// True if `value` immediately follows `flag` somewhere in `args`.
private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
    for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value {
        return true
    }
    return false
}
