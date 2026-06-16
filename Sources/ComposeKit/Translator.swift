//===----------------------------------------------------------------------===//
// Translate Compose services into `container` CLI invocations.
//
// This is where compatibility decisions live. Anything Compose can express but
// `container` cannot is marked with `UNSUPPORTED:` and either approximated or
// skipped (with a warning emitted by the Orchestrator).
//===----------------------------------------------------------------------===//

import Foundation

public struct Translator: Sendable {
    public let project: String
    public let baseDirectory: URL
    public let hostEnv: [String: String]

    /// Labels used to associate resources with this Compose project.
    public static let projectLabel = "com.apple.container.compose.project"
    public static let serviceLabel = "com.apple.container.compose.service"
    public static let restartLabel = "com.apple.container.compose.restart"

    public init(project: String, baseDirectory: URL, hostEnv: [String: String]) {
        self.project = project
        self.baseDirectory = baseDirectory
        self.hostEnv = hostEnv
    }

    // MARK: - Resource naming (project-scoped)

    public func containerName(service: String, declared: String?) -> String {
        declared ?? "\(project)-\(service)"
    }

    public func networkName(_ name: String) -> String { "\(project)-\(name)" }
    public func volumeName(_ name: String) -> String { "\(project)-\(name)" }
    public var defaultNetwork: String { "\(project)-default" }

    /// Built image tag for a service that has `build` but no `image`.
    public func builtImageTag(service: String) -> String { "\(project)-\(service):latest" }

    // MARK: - Build

    /// `container build` args for a service with a `build` section.
    public func buildArgs(service: String, _ svc: Service) -> [String]? {
        guard let build = svc.build else { return nil }
        let tag = svc.image ?? builtImageTag(service: service)
        var a = ["build", "--tag", tag]
        if let dockerfile = build.dockerfile {
            a += ["--file", resolvePath(dockerfile, relativeTo: build.contextPath)]
        }
        if let target = build.target {
            a += ["--target", target]
        }
        if let args = build.args {
            for pair in args.pairs(hostEnv: hostEnv) { a += ["--build-arg", pair] }
        }
        a += [resolvePath(build.contextPath)]
        return a
    }

    // MARK: - Run

    /// `container run` args for one service.
    public func runArgs(service name: String, _ svc: Service, image: String) -> [String] {
        var a = ["run", "--detach"]
        a += ["--name", containerName(service: name, declared: svc.container_name)]

        // Project bookkeeping labels.
        a += ["--label", "\(Self.projectLabel)=\(project)"]
        a += ["--label", "\(Self.serviceLabel)=\(name)"]
        if let restart = svc.restart {
            // UNSUPPORTED: no `--restart`; recorded as a label only (not enforced).
            a += ["--label", "\(Self.restartLabel)=\(restart)"]
        }

        // Environment.
        if let env = svc.environment {
            for pair in env.pairs(hostEnv: hostEnv) { a += ["--env", pair] }
        }
        if let envFiles = svc.env_file {
            for f in envFiles.values { a += ["--env-file", resolvePath(f)] }
        }

        // Ports.
        if let ports = svc.ports {
            for p in ports { a += ["--publish", p.publishArgument] }
        }

        // Volumes / mounts.
        if let vols = svc.volumes {
            for v in vols { a += volumeArguments(v) }
        }

        // Networks (attach to project default when none declared).
        let nets = svc.networks?.names ?? []
        if nets.isEmpty {
            a += ["--network", defaultNetwork]
        } else {
            for n in nets { a += ["--network", networkName(n)] }
        }

        // User-defined labels.
        if let labels = svc.labels {
            for pair in labels.pairs() { a += ["--label", pair] }
        }

        // Process / management flags.
        if let cwd = svc.working_dir { a += ["--workdir", cwd] }
        if let user = svc.user { a += ["--user", user] }
        for cap in svc.cap_add ?? [] { a += ["--cap-add", cap] }
        for cap in svc.cap_drop ?? [] { a += ["--cap-drop", cap] }
        for d in svc.dns?.values ?? [] { a += ["--dns", d] }
        for t in svc.tmpfs?.values ?? [] { a += ["--tmpfs", t] }
        if svc.read_only == true { a += ["--read-only"] }
        if svc.`init` == true { a += ["--init"] }
        if let platform = svc.platform { a += ["--platform", platform] }

        // Resource limits (deploy.resources.limits wins, then top-level shorthands).
        if let cpus = svc.deploy?.resources?.limits?.cpus?.stringValue ?? svc.cpus?.stringValue {
            a += ["--cpus", cpus]
        }
        if let mem = svc.deploy?.resources?.limits?.memory ?? svc.mem_limit {
            a += ["--memory", mem]
        }

        // Entrypoint (container takes a single string; extra tokens go to command).
        var trailing: [String] = []
        if let entrypoint = svc.entrypoint {
            let values = entrypoint.values
            if let first = values.first {
                a += ["--entrypoint", first]
                trailing += Array(values.dropFirst())
            }
        }

        // Image, then command.
        a += [image]
        if let command = svc.command {
            switch command {
            case .list(let arr):
                trailing += arr
            case .string(let s):
                // Compose string form runs through a shell.
                trailing += ["/bin/sh", "-c", s]
            }
        }
        a += trailing
        return a
    }

    // MARK: - Helpers

    private func volumeArguments(_ mount: VolumeMount) -> [String] {
        switch mount {
        case .short(let raw):
            let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else {
                // Anonymous volume: just a container path.
                return ["--volume", raw]
            }
            let source = resolveVolumeSource(parts[0])
            let rest = parts[1...].joined(separator: ":")
            return ["--volume", "\(source):\(rest)"]

        case .long(let lv):
            switch lv.type {
            case "tmpfs":
                return ["--tmpfs", lv.target]
            case "bind":
                var arg = "\(resolvePath(lv.source ?? ".")):\(lv.target)"
                if lv.read_only == true { arg += ":ro" }
                return ["--volume", arg]
            default:  // "volume" or unset
                let source = lv.source.map { volumeName($0) }
                var arg = source.map { "\($0):\(lv.target)" } ?? lv.target
                if lv.read_only == true { arg += ":ro" }
                return ["--volume", arg]
            }
        }
    }

    /// A short-form volume source is a bind path if it looks like one,
    /// otherwise a named (project-scoped) volume.
    private func resolveVolumeSource(_ source: String) -> String {
        if source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") {
            return resolvePath(source)
        }
        return volumeName(source)
    }

    /// Resolve a host path against the Compose file's directory (and `~`).
    public func resolvePath(_ path: String, relativeTo subdir: String? = nil) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        var base = baseDirectory
        if let subdir, !subdir.hasPrefix("/") {
            base = base.appendingPathComponent(subdir)
        } else if let subdir {
            base = URL(fileURLWithPath: subdir)
        }
        return base.appendingPathComponent(path).standardizedFileURL.path
    }
}
