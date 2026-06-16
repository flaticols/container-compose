//===----------------------------------------------------------------------===//
// High-level Compose operations, built on Translator + ContainerRunner.
//===----------------------------------------------------------------------===//

import Foundation

public struct Orchestrator: Sendable {
    public let project: Project
    public let runner: ContainerRunner
    public let translator: Translator

    public init(project: Project, runner: ContainerRunner) {
        self.project = project
        self.runner = runner
        self.translator = Translator(
            project: project.name,
            baseDirectory: project.baseDirectory,
            hostEnv: project.variables
        )
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("container-compose: warning: \(message)\n".utf8))
    }

    private func info(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    // MARK: - up

    public func up(build: Bool, only services: [String]) throws {
        let selected = try select(services)
        try ensureNetworks()
        try ensureVolumes()

        let order = try Planner.startOrder(project.file.services).filter { selected.contains($0) }
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let image = try imageForService(name: name, svc: svc, forceBuild: build)
            warnUnsupported(name: name, svc: svc)

            // Wait on any `depends_on: condition: service_healthy` dependencies.
            try gateDependencies(of: name, svc, selected: selected)

            // Recreate semantics: remove any stale container with the same name.
            let cname = translator.containerName(service: name, declared: svc.container_name)
            runner.runSilently(["delete", "--force", cname])

            info("Creating \(cname) ...")
            try runner.runChecked(translator.runArgs(service: name, svc, image: image))
        }
    }

    /// Block on `service_healthy` dependencies that were also selected for `up`.
    private func gateDependencies(of name: String, _ svc: Service, selected: Set<String>) throws {
        guard let deps = svc.depends_on else { return }
        for dep in deps.names where selected.contains(dep) {
            guard deps.condition(for: dep) == "service_healthy" else { continue }
            guard let depSvc = project.file.services[dep] else { continue }
            let depContainer = translator.containerName(service: dep, declared: depSvc.container_name)
            if let hc = depSvc.healthcheck, hc.disable != true,
                let test = hc.test, HealthChecker.execArguments(for: test) != nil
            {
                info("Waiting for '\(dep)' to be healthy ...")
                try HealthChecker(runner: runner).waitHealthy(container: depContainer, health: hc)
            } else {
                warn(
                    "service '\(name)': depends_on '\(dep)' wants service_healthy but "
                        + "'\(dep)' defines no healthcheck; starting without gating")
            }
        }
    }

    private func imageForService(name: String, svc: Service, forceBuild: Bool) throws -> String {
        if svc.build != nil, forceBuild || svc.image == nil {
            if let buildArgs = translator.buildArgs(service: name, svc) {
                info("Building \(name) ...")
                try runner.runChecked(buildArgs)
            }
            return svc.image ?? translator.builtImageTag(service: name)
        }
        guard let image = svc.image else {
            throw ComposeError.serviceMissingImage(name)
        }
        return image
    }

    // MARK: - down

    public func down(removeVolumes: Bool) throws {
        // Stop & remove in reverse dependency order.
        let order = try Planner.startOrder(project.file.services).reversed()
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Removing \(cname) ...")
            runner.runSilently(["stop", cname])
            runner.runSilently(["delete", "--force", cname])
        }

        // Remove project networks (default + declared).
        var networks = [translator.defaultNetwork]
        networks += (project.file.networks?.keys ?? Dictionary<String, NetworkSpec?>().keys).map {
            translator.networkName($0)
        }
        for net in networks {
            runner.runSilently(["network", "delete", net])
        }

        if removeVolumes {
            for volName in project.file.volumes?.keys ?? Dictionary<String, VolumeSpec?>().keys {
                runner.runSilently(["volume", "delete", translator.volumeName(volName)])
            }
        }
    }

    // MARK: - ps

    /// List this project's containers. Uses a name-prefix filter over
    /// `container list` output (the CLI's JSON schema is not depended upon).
    public func ps(all: Bool) throws {
        var args = ["list"]
        if all { args.append("--all") }
        let (status, out) = try runner.capture(args)
        guard status == 0 else { throw ContainerRunner.RunnerError.nonZeroExit(command: args, status: status) }

        let prefix = "\(project.name)-"
        let declaredNames = Set(
            project.file.services.map { name, svc in
                translator.containerName(service: name, declared: svc.container_name)
            }
        )
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return }
        print(header)
        for line in lines.dropFirst() {
            let belongs = line.contains(prefix) || declaredNames.contains { line.contains($0) }
            if belongs { print(line) }
        }
    }

    // MARK: - logs

    public func logs(follow: Bool, only services: [String]) throws {
        let selected = try select(services).sorted()
        if follow && selected.count > 1 {
            warn("--follow with multiple services tails them sequentially; pass one service to stream live")
        }
        for name in selected {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            var args = ["logs"]
            if follow { args.append("--follow") }
            args.append(cname)
            _ = try? runner.run(args)
        }
    }

    // MARK: - shared helpers

    private func select(_ services: [String]) throws -> Set<String> {
        guard !services.isEmpty else { return Set(project.file.services.keys) }
        for s in services where project.file.services[s] == nil {
            throw ComposeError.unknownService(s)
        }
        return Set(services)
    }

    private func ensureNetworks() throws {
        var toCreate: [(name: String, spec: NetworkSpec?)] = [(translator.defaultNetwork, nil)]
        for (declared, spec) in project.file.networks ?? [:] {
            // External networks are assumed to already exist.
            if spec?.external?.isExternal == true { continue }
            toCreate.append((translator.networkName(declared), spec))
        }
        for (name, spec) in toCreate {
            var args = ["network", "create"]
            if spec?.`internal` == true { args.append("--internal") }
            if let subnet = spec?.subnet { args += ["--subnet", subnet] }
            args.append(name)
            // Best-effort and idempotent: an existing network is silently reused
            // (Docker-compatible). A genuine failure surfaces when `run` uses it.
            runner.runSilently(args)
        }
    }

    private func ensureVolumes() throws {
        // Declared top-level named volumes.
        var names = Set<String>()
        for (declared, spec) in project.file.volumes ?? [:] {
            if spec?.external?.isExternal == true { continue }
            names.insert(declared)
        }
        for name in names.sorted() {
            // Idempotent: an existing volume is reused.
            runner.runSilently(["volume", "create", translator.volumeName(name)])
        }
    }

    private func warnUnsupported(name: String, svc: Service) {
        if svc.restart != nil {
            warn("service '\(name)': 'restart' is recorded as a label but not enforced by container")
        }
        if svc.privileged == true {
            warn("service '\(name)': 'privileged' has no container equivalent and is ignored")
        }
    }
}
