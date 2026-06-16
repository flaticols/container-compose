import Foundation
import Testing

@testable import ComposeKit

private func loadFixture() throws -> Project {
    let url = Bundle.module.url(forResource: "compose", withExtension: "yaml", subdirectory: "Fixtures")!
    let dir = url.deletingLastPathComponent()
    return try Project.load(explicit: url.path, projectName: nil, cwd: dir)
}

@Suite("Compose parsing")
struct ParsingTests {
    @Test("project name comes from top-level name:")
    func projectName() throws {
        let project = try loadFixture()
        #expect(project.name == "demo")
    }

    @Test("all services parse")
    func services() throws {
        let project = try loadFixture()
        #expect(Set(project.file.services.keys) == ["db", "cache", "web"])
    }

    @Test("polymorphic environment: map and list forms")
    func environment() throws {
        let project = try loadFixture()
        let db = project.file.services["db"]!
        #expect(db.environment?.pairs().contains("POSTGRES_USER=app") == true)
        let web = project.file.services["web"]!
        #expect(web.environment?.pairs().contains("DATABASE_URL=postgres://app@db:5432/app") == true)
    }

    @Test("depends_on map form yields names")
    func dependsOn() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        #expect(Set(web.depends_on?.names ?? []) == ["db", "cache"])
    }

    @Test("build long form")
    func build() throws {
        let project = try loadFixture()
        let web = project.file.services["web"]!
        #expect(web.build?.contextPath == "./web")
        #expect(web.build?.dockerfile == "Dockerfile")
    }
}

@Suite("Planning")
struct PlanningTests {
    @Test("start order respects depends_on")
    func startOrder() throws {
        let project = try loadFixture()
        let order = try Planner.startOrder(project.file.services)
        let webIndex = order.firstIndex(of: "web")!
        #expect(order.firstIndex(of: "db")! < webIndex)
        #expect(order.firstIndex(of: "cache")! < webIndex)
    }

    @Test("cycle is detected")
    func cycle() throws {
        // a -> b -> a
        let yaml = """
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: y
                depends_on: [a]
            """
        let file = try ComposeFile.parse(yaml: yaml)
        #expect(throws: ComposeError.self) {
            _ = try Planner.startOrder(file.services)
        }
    }
}

@Suite("Translation")
struct TranslationTests {
    private func translator() -> Translator {
        Translator(project: "demo", baseDirectory: URL(fileURLWithPath: "/proj"), hostEnv: [:])
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
        #expect(adjacent(args, "--cpus", "0.5"))
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
}

@Suite("Interpolation")
struct InterpolationTests {
    let vars = ["NAME": "web", "EMPTY": "", "TAG": "1.2.3"]

    @Test("simple and braced forms")
    func simple() throws {
        #expect(try Interpolator.expand("$NAME:${TAG}", variables: vars) == "web:1.2.3")
    }

    @Test("escaped dollar")
    func escaped() throws {
        #expect(try Interpolator.expand("price $$5", variables: vars) == "price $5")
    }

    @Test("default operators")
    func defaults() throws {
        #expect(try Interpolator.expand("${MISSING:-fallback}", variables: vars) == "fallback")
        #expect(try Interpolator.expand("${EMPTY:-fallback}", variables: vars) == "fallback")
        #expect(try Interpolator.expand("${EMPTY-keep}", variables: vars) == "")  // set-but-empty
        #expect(try Interpolator.expand("${NAME:+yes}", variables: vars) == "yes")
        #expect(try Interpolator.expand("${MISSING:+yes}", variables: vars) == "")
    }

    @Test("required operator throws when unset")
    func required() throws {
        #expect(throws: ComposeError.self) {
            _ = try Interpolator.expand("${MISSING:?must be set}", variables: vars)
        }
    }

    @Test("unset variable becomes empty")
    func unset() throws {
        #expect(try Interpolator.expand("[${MISSING}]", variables: vars) == "[]")
    }
}

@Suite("EnvFile")
struct EnvFileTests {
    @Test("parses keys, quotes, exports, comments")
    func parse() {
        let env = EnvFile.parse(
            """
            # comment
            export FOO=bar
            QUOTED="hello world"
            SINGLE='raw $value'
            INLINE=value # trailing
            EMPTY=
            """)
        #expect(env["FOO"] == "bar")
        #expect(env["QUOTED"] == "hello world")
        #expect(env["SINGLE"] == "raw $value")
        #expect(env["INLINE"] == "value")
        #expect(env["EMPTY"] == "")
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

/// True if `value` immediately follows `flag` somewhere in `args`.
private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
    for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value {
        return true
    }
    return false
}
