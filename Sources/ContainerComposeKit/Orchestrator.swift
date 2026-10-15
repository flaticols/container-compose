import ComposeKit
import Foundation

/// High-level Compose operations (`up`, `down`, `ps`, `logs`), built on top of
/// ``ContainerTranslator`` and ``ContainerRunner``.
///
/// The orchestrator owns the side effects the translator avoids: it creates
/// project networks and volumes, materializes `content:`/`environment:`
/// configs and secrets, gates `depends_on` conditions, and spawns `container`
/// commands in dependency order. Construct one from a loaded `Project`.
public struct Orchestrator: Sendable {
    /// The loaded project being operated on.
    public let project: Project
    /// The runner used to invoke the `container` CLI.
    public let runner: ContainerRunner
    /// The translator mapping services to `container` argument vectors.
    public let translator: ContainerTranslator
    /// The per-container hosts files mounted into services for name resolution.
    public let hosts: ProjectHosts

    /// Create an orchestrator for a loaded `Project`, wiring a
    /// ``ContainerTranslator`` from the project's identity and variables.
    ///
    /// - Parameter stateDirectory: root for per-project state such as hosts
    ///   files; defaults to ``ProjectHosts/defaultRoot(environment:)``.
    public init(project: Project, runner: ContainerRunner, stateDirectory: URL? = nil) {
        self.project = project
        self.runner = runner
        self.translator = ContainerTranslator(
            project: project.name,
            baseDirectory: project.baseDirectory,
            hostEnv: project.variables
        )
        let root = stateDirectory ?? ProjectHosts.defaultRoot()
        self.hosts = ProjectHosts(
            directory: root.appendingPathComponent(project.name, isDirectory: true)
                .appendingPathComponent("hosts", isDirectory: true))
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("container-compose: warning: \(message)\n".utf8))
    }

    private func info(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    // MARK: - up

    /// Create and start the project's services in dependency order.
    ///
    /// Provisions networks and volumes, resolves configs/secrets, honors
    /// `depends_on` conditions (waiting on `service_healthy`, running
    /// `service_completed_successfully` dependencies to completion), and recreates
    /// any stale containers.
    ///
    /// - Parameters:
    ///   - build: force a `container build` for services that have a `build:`
    ///     section, even when an `image:` already exists.
    ///   - services: limit the operation to these services (and their
    ///     dependencies); empty means every profile-enabled service.
    ///   - wait: block until every started service with a healthcheck is healthy.
    ///   - removeOrphans: remove project containers whose service is no longer
    ///     declared; otherwise they are only warned about.
    /// - Throws: `ComposeError` for unknown services, dependency cycles, or a
    ///   dependency that fails to become healthy or complete successfully.
    public func up(
        build: Bool, only services: [String], wait: Bool = false, removeOrphans: Bool = false
    ) async throws {
        try validate(services)
        let selected = project.enabledServices(explicit: services)
        try await ensureNetworks()
        try await ensureVolumes()

        var book = try await addressBook(for: selected)
        let orphans = orphans(in: Array(book.records.values))
        if !orphans.isEmpty {
            if removeOrphans {
                try await remove(orphans: orphans)
                for orphan in orphans { book.records[orphan.id] = nil }
            } else {
                warn(
                    "found orphan containers (\(orphans.map(\.id).sorted().joined(separator: ", "))) "
                        + "for this project; remove them with `down --remove-orphans`")
            }
        }

        // Services that a selected service depends on with
        // `condition: service_completed_successfully` — run these to completion.
        let oneShot = completedSuccessfullyTargets(selected: selected)
        let resolved = resolveFileObjects(selected: selected)

        let order = try Planner.startOrder(project.file.services).filter { selected.contains($0) }
        var healthyDependencies = Set<String>()
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let image = try await imageForService(
                name: name, svc: svc, forceBuild: build, buildSecrets: resolved.secrets)
            warnUnsupported(name: name, svc: svc)

            // Wait on any `depends_on: condition: service_healthy` dependencies.
            let newlyHealthy = try await gateDependencies(
                of: name, svc, selected: selected, alreadyHealthy: healthyDependencies)
            healthyDependencies.formUnion(newlyHealthy)

            // Recreate semantics: remove any stale container with the same name.
            let cname = translator.containerName(service: name, declared: svc.container_name)
            try await runner.runSilently(["delete", "--force", cname])
            book.records[cname] = nil

            // The hosts file must exist before `run` mounts it; it lists the
            // peers started so far (all dependencies, by topological order).
            let hostsFile = try writeHosts(service: name, svc, book: book)

            // One-shot dependency: run attached and use the exit code as the gate
            // (`container` has no `wait`); a non-zero exit aborts `up`. Topological
            // order guarantees it completes before any dependent starts.
            if oneShot.contains(name) {
                info("Running \(cname) (one-shot) ...")
                let args = translator.runArgs(
                    service: name, svc, image: image, detach: false, files: resolved,
                    hostsFile: hostsFile)
                let status = try await runner.run(args)
                if status != 0 { throw ComposeError.dependencyFailed(name, status) }
            } else {
                info("Creating \(cname) ...")
                try await runner.runChecked(
                    translator.runArgs(
                        service: name, svc, image: image, files: resolved, hostsFile: hostsFile))
                try await noteStarted(cname, book: &book)
            }
        }

        if wait { try await waitUntilHealthy(order: order, oneShot: oneShot) }
    }

    /// Block until every started service that defines a healthcheck reports
    /// healthy. Services without a healthcheck are considered ready once created;
    /// one-shot (`service_completed_successfully`) services already ran to exit.
    private func waitUntilHealthy(order: [String], oneShot: Set<String>) async throws {
        var checks: [(name: String, container: String, health: Healthcheck)] = []
        for name in order where !oneShot.contains(name) {
            guard let svc = project.file.services[name], let health = svc.healthcheck,
                health.disable != true, let test = health.test,
                HealthChecker.execArguments(for: test) != nil
            else { continue }
            checks.append(
                (
                    name,
                    translator.containerName(service: name, declared: svc.container_name),
                    health
                ))
        }

        let checker = HealthChecker(runner: runner)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for check in checks {
                info("Waiting for '\(check.name)' to be healthy ...")
                group.addTask {
                    try await checker.waitHealthy(
                        container: check.container, health: check.health)
                }
            }
            while let _ = try await group.next() {}
        }
    }

    /// Names of services that any selected service depends on with the
    /// `service_completed_successfully` condition.
    private func completedSuccessfullyTargets(selected: Set<String>) -> Set<String> {
        var targets = Set<String>()
        for name in selected {
            guard let deps = project.file.services[name]?.depends_on else { continue }
            for dep in deps.names
            where selected.contains(dep)
                && deps.condition(for: dep) == "service_completed_successfully" {
                targets.insert(dep)
            }
        }
        return targets
    }

    /// Block on `service_healthy` dependencies that were also selected for `up`.
    /// Dependencies that passed an earlier gate are not polled again.
    private func gateDependencies(
        of name: String, _ svc: Service, selected: Set<String>,
        alreadyHealthy: Set<String>
    ) async throws -> Set<String> {
        guard let deps = svc.depends_on else { return [] }
        var checks: [(name: String, container: String, health: Healthcheck)] = []
        for dep in deps.names where selected.contains(dep) && !alreadyHealthy.contains(dep) {
            guard deps.condition(for: dep) == "service_healthy" else { continue }
            guard let depSvc = project.file.services[dep] else { continue }
            if let health = depSvc.healthcheck, health.disable != true,
                let test = health.test, HealthChecker.execArguments(for: test) != nil
            {
                checks.append(
                    (
                        dep,
                        translator.containerName(
                            service: dep, declared: depSvc.container_name),
                        health
                    ))
            } else {
                warn(
                    "service '\(name)': depends_on '\(dep)' wants service_healthy but "
                        + "'\(dep)' defines no healthcheck; starting without gating")
            }
        }

        let checker = HealthChecker(runner: runner)
        return try await withThrowingTaskGroup(of: String.self) { group in
            for check in checks {
                info("Waiting for '\(check.name)' to be healthy ...")
                group.addTask {
                    try await checker.waitHealthy(
                        container: check.container, health: check.health)
                    return check.name
                }
            }

            var healthy = Set<String>()
            while let name = try await group.next() {
                healthy.insert(name)
            }
            return healthy
        }
    }

    /// Resolve every config/secret source referenced by a selected service to a
    /// host file path: `file:` is resolved against the project dir;
    /// `content:`/`environment:` are materialized to a temp file (honoring `mode`).
    /// `external:`, undefined, and source-less entries are warned and skipped;
    /// `uid`/`gid` are warned (need root), and `mode` on a `file:` source is
    /// warned (the file isn't ours to chmod).
    private func resolveFileObjects(selected: Set<String>) -> ContainerTranslator.ResolvedFileObjects {
        var configs: [String: String] = [:]
        var secrets: [String: String] = [:]

        func resolve(
            kind: String,
            defs: [String: FileObjectSpec?]?,
            refsFor: (Service) -> [ServiceFileRef]?,
            into out: inout [String: String]
        ) {
            var referenced = Set<String>()
            var modeFor: [String: String] = [:]  // source -> requested mode (last wins)
            for name in selected {
                guard let svc = project.file.services[name] else { continue }
                for ref in refsFor(svc) ?? [] {
                    referenced.insert(ref.source)
                    if case .long(let l) = ref {
                        if l.uid != nil || l.gid != nil {
                            warn("service '\(name)': \(kind) '\(ref.source)' uid/gid "
                                + "are not enforced by container")
                        }
                        if let mode = l.mode?.stringValue { modeFor[ref.source] = mode }
                    }
                }
            }
            for source in referenced.sorted() {
                guard let spec = defs?[source] ?? nil else {
                    warn("\(kind) '\(source)' is referenced but not defined; skipping")
                    continue
                }
                let mode = modeFor[source]
                if spec.external?.isExternal == true {
                    warn("\(kind) '\(source)' is external; container cannot resolve it, skipping")
                } else if let file = spec.file {
                    out[source] = translator.resolvePath(file)
                    if mode != nil {
                        warn("\(kind) '\(source)': mode is not applied to a file: source")
                    }
                } else if let content = spec.content {
                    if let p = materialize(kind: kind, name: source, content: content, mode: mode) {
                        out[source] = p
                    }
                } else if let envName = spec.environment {
                    let value = project.variables[envName] ?? ""
                    if let p = materialize(kind: kind, name: source, content: value, mode: mode) {
                        out[source] = p
                    }
                } else {
                    warn("\(kind) '\(source)' has no file/content/environment source; skipping")
                }
            }
        }

        // Secret sources come from both service `secrets:` and `build.secrets`.
        resolve(
            kind: "secret", defs: project.file.secrets,
            refsFor: { ($0.secrets ?? []) + ($0.build?.long?.secrets ?? []) }, into: &secrets)
        resolve(kind: "config", defs: project.file.configs, refsFor: { $0.configs }, into: &configs)
        return .init(configs: configs, secrets: secrets)
    }

    /// Write inline `content:`/`environment:` source data to a temp file and
    /// return its path, applying `mode` (octal, e.g. `0440`) when given. During a
    /// dry run nothing is written (the path is still returned so the planned mount
    /// is visible).
    private func materialize(kind: String, name: String, content: String, mode: String? = nil)
        -> String?
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composekit-\(project.name)", isDirectory: true)
            .appendingPathComponent("\(kind)s", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        if runner.dryRun { return url.path }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            if let mode, let bits = Self.parseMode(mode) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: bits)], ofItemAtPath: url.path)
            }
            return url.path
        } catch {
            warn("\(kind) '\(name)': failed to materialize content (\(error)); skipping")
            return nil
        }
    }

    /// Parse a Compose file `mode` to permission bits. Accepts `0440`/`0o440`
    /// (octal) and a plain decimal whose value is already the mode bits (e.g.
    /// YAML may decode `0440` to the integer `288`, which is `0o440`).
    static func parseMode(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0o") || s.hasPrefix("0O") { return Int(s.dropFirst(2), radix: 8) }
        if s.count > 1, s.hasPrefix("0") { return Int(s, radix: 8) }
        return Int(s)
    }

    private func imageForService(
        name: String, svc: Service, forceBuild: Bool, buildSecrets: [String: String]
    ) async throws -> String {
        if svc.build != nil, forceBuild || svc.image == nil {
            if let buildArgs = translator.buildArgs(
                service: name, svc, resolvedSecrets: buildSecrets)
            {
                info("Building \(name) ...")
                try await runner.runChecked(buildArgs)
            }
            return svc.image ?? translator.builtImageTag(service: name)
        }
        guard let image = svc.image else {
            throw ComposeError.serviceMissingImage(name)
        }
        return image
    }

    // MARK: - down

    /// Stop and remove the project's containers and networks (in reverse
    /// dependency order), optionally removing named volumes too.
    ///
    /// - Parameters:
    ///   - removeVolumes: also delete the project's declared named volumes
    ///     (data loss); defaults to keeping them.
    ///   - removeOrphans: also remove project containers whose service is no
    ///     longer declared in the Compose file.
    public func down(removeVolumes: Bool, removeOrphans: Bool = false) async throws {
        // Stop & remove in reverse dependency order.
        let order = try Planner.startOrder(project.file.services).reversed()
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Removing \(cname) ...")
            try await runner.runSilently(["stop", cname])
            try await runner.runSilently(["delete", "--force", cname])
        }
        if removeOrphans {
            try await remove(orphans: orphans(in: try await projectContainers()))
        }
        do {
            try hosts.remove()
        } catch {
            warn("could not remove hosts files at \(hosts.directory.path): \(error)")
        }

        // Remove project networks (default + declared).
        var networks = [translator.defaultNetwork]
        networks += (project.file.networks ?? [:]).keys.map { translator.networkName($0) }
        for net in networks {
            try await runner.runSilently(["network", "delete", net])
        }

        if removeVolumes {
            for volName in (project.file.volumes ?? [:]).keys {
                try await runner.runSilently(["volume", "delete", translator.volumeName(volName)])
            }
        }
    }

    // MARK: - ps

    /// Print the project's containers, filtered from `container list` by name
    /// prefix (the CLI's JSON schema is intentionally not depended upon).
    ///
    /// - Parameter all: include stopped containers (`container list --all`).
    public func ps(all: Bool) async throws {
        var args = ["list"]
        if all { args.append("--all") }
        let (status, out) = try await runner.capture(args)
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

    /// Print logs for the selected services (all of them when `services` is empty).
    ///
    /// - Parameters:
    ///   - follow: stream new output (`container logs --follow`). With more than
    ///     one service this tails them sequentially; pass a single service to
    ///     stream live.
    ///   - services: limit to these services; empty means all.
    public func logs(
        follow: Bool, tail: Int? = nil, only services: [String]
    ) async throws {
        let selected = try select(services).sorted()
        if follow && selected.count > 1 {
            warn("--follow with multiple services tails them sequentially; pass one service to stream live")
        }
        for name in selected {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            var args = ["logs"]
            if follow { args.append("--follow") }
            if let tail { args += ["-n", String(tail)] }
            args.append(cname)
            _ = try? await runner.run(args)
        }
    }

    // MARK: - exec

    /// Run a command inside a running service's container, inheriting stdio so
    /// interactive shells work.
    ///
    /// - Parameters:
    ///   - service: the service whose container to exec into.
    ///   - command: the command and arguments to run.
    ///   - interactive: keep stdin open (`-i`).
    ///   - tty: allocate a TTY (`-t`).
    ///   - workdir: working directory inside the container (`--workdir`).
    ///   - user: user to run as, `name|uid[:gid]` (`--user`).
    ///   - env: extra `KEY=VALUE` environment entries (`--env`, repeatable).
    /// - Returns: the command's exit status.
    /// - Throws: `ComposeError.unknownService` if the service is undeclared.
    @discardableResult
    public func exec(
        service: String, command: [String], interactive: Bool = false, tty: Bool = false,
        workdir: String? = nil, user: String? = nil, env: [String] = []
    ) async throws -> Int32 {
        try validate([service])
        let svc = project.file.services[service]
        let cname = translator.containerName(service: service, declared: svc?.container_name)
        var args = ["exec"]
        if interactive { args.append("--interactive") }
        if tty { args.append("--tty") }
        if let workdir { args += ["--workdir", workdir] }
        if let user { args += ["--user", user] }
        for entry in env { args += ["--env", entry] }
        args.append(cname)
        args += command
        return try await runner.run(args)
    }

    // MARK: - pull

    /// Pre-fetch images for the selected services. Build-only services (no
    /// `image:`) and duplicate image references are skipped.
    ///
    /// - Parameter services: limit to these services; empty means all.
    public func pull(only services: [String]) async throws {
        let selected = try select(services)
        var pulled = Set<String>()
        for name in selected.sorted() {
            guard let svc = project.file.services[name], let image = svc.image, svc.build == nil
            else { continue }
            guard pulled.insert(image).inserted else { continue }
            info("Pulling \(image) ...")
            try await runner.runChecked(["image", "pull", image])
        }
    }

    // MARK: - stop / start / restart

    /// Stop the selected services' containers (reverse dependency order) without
    /// removing them. Best-effort: an already-stopped container is ignored.
    public func stop(only services: [String]) async throws {
        for name in try ordered(services, reversed: true) {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Stopping \(cname) ...")
            try await runner.runSilently(["stop", cname])
        }
    }

    /// Start previously-created containers for the selected services (dependency
    /// order) without recreating them. Containers get new addresses on start, so
    /// the project's hosts files are refreshed as each one comes up.
    public func start(only services: [String]) async throws {
        let order = try ordered(services, reversed: false)
        var book = try await addressBook(for: Set(order))
        for name in order {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Starting \(cname) ...")
            try await runner.runChecked(["start", cname])
            try await noteStarted(cname, book: &book)
        }
    }

    /// Restart the selected services (stop then start). `container` has no native
    /// restart command, so this is implemented as a stop followed by a start.
    public func restart(only services: [String]) async throws {
        try await stop(only: services)
        try await start(only: services)
    }

    /// Send a signal (default KILL) to the selected services' containers, in
    /// reverse dependency order. Best-effort, like ``stop(only:)``.
    ///
    /// - Parameter signal: the signal to send (e.g. `SIGTERM`); `nil` uses the
    ///   `container` default (KILL).
    public func kill(only services: [String], signal: String? = nil) async throws {
        for name in try ordered(services, reversed: true) {
            guard let svc = project.file.services[name] else { continue }
            let cname = translator.containerName(service: name, declared: svc.container_name)
            info("Killing \(cname) ...")
            var args = ["kill"]
            if let signal { args += ["--signal", signal] }
            args.append(cname)
            try await runner.runSilently(args)
        }
    }

    // MARK: - shared helpers

    private func select(_ services: [String]) throws -> Set<String> {
        guard !services.isEmpty else { return Set(project.file.services.keys) }
        try validate(services)
        return Set(services)
    }

    /// Throw on any name that isn't a declared service.
    private func validate(_ services: [String]) throws {
        for s in services where project.file.services[s] == nil {
            throw ComposeError.unknownService(s)
        }
    }

    /// Selected services in dependency order (optionally reversed).
    private func ordered(_ services: [String], reversed: Bool) throws -> [String] {
        let selected = try select(services)
        let order = try Planner.startOrder(project.file.services).filter { selected.contains($0) }
        return reversed ? order.reversed() : order
    }

    // MARK: - Name resolution & orphans

    /// What is known about the project's containers while services start: their
    /// records (by container name), the gateway of each network, and whether the
    /// generated hosts files should carry the `host.docker.internal` entries.
    private struct AddressBook {
        var records: [String: ContainerRecord] = [:]
        var gateways: [String: String] = [:]
        var hostEntries = true

        mutating func note(_ record: ContainerRecord) {
            records[record.id] = record
            for attachment in record.networks {
                if let gateway = attachment.ipv4Gateway { gateways[attachment.network] = gateway }
            }
        }
    }

    /// Runtime network names a service attaches to, primary first.
    private func runtimeNetworks(_ svc: Service) -> [String] {
        let declared = svc.networks?.names ?? []
        return declared.isEmpty ? [translator.defaultNetwork] : declared.map(translator.networkName)
    }

    /// Project containers known to `container`, in any state. Parse failures are
    /// warned and treated as "none", so a schema change degrades name resolution
    /// and orphan detection rather than aborting the command.
    private func projectContainers() async throws -> [ContainerRecord] {
        let (status, out) = try await runner.capture(["list", "--all", "--format", "json"])
        guard status == 0 else { return [] }
        do {
            return try ContainerRecord.decodeList(out).filter { $0.project == project.name }
        } catch {
            warn("could not parse `container list` output (\(error)); "
                + "service names and orphans may not be detected")
            return []
        }
    }

    /// Seed the address book from the project's containers in any state (a
    /// stopped one has no addresses but still counts for orphan detection), the
    /// gateways of every network the selected services use, and the registered
    /// DNS domains.
    private func addressBook(for selected: Set<String>) async throws -> AddressBook {
        var book = AddressBook()
        for record in try await projectContainers() {
            book.note(record)
        }

        var wanted: [String] = []
        for name in selected.sorted() {
            guard let svc = project.file.services[name] else { continue }
            for network in runtimeNetworks(svc) where book.gateways[network] == nil && !wanted.contains(network) {
                wanted.append(network)
            }
        }
        if !wanted.isEmpty {
            let (status, out) = try await runner.capture(["network", "inspect"] + wanted)
            if status == 0, let networks = try? NetworkRecord.decodeList(out) {
                for network in networks {
                    if let gateway = network.ipv4Gateway { book.gateways[network.id] = gateway }
                }
            }
        }

        // A user-registered `host.docker.internal` DNS domain (Apple's route to
        // localhost-bound Mac services) must not be shadowed by /etc/hosts.
        book.hostEntries = !(await registeredDNSDomains()).contains(ProjectHosts.hostNames[0])
        return book
    }

    /// Domains registered with `container system dns create`; empty on any failure.
    private func registeredDNSDomains() async -> Set<String> {
        guard let (status, out) = try? await runner.capture(["system", "dns", "list", "--format", "json"]),
            status == 0,
            let domains = try? JSONDecoder().decode([String].self, from: Data(out.utf8))
        else { return [] }
        return Set(domains)
    }

    /// Peers for hosts rendering: every recorded container that runs a declared
    /// service, under its service name, container name, and network aliases.
    private func peers(in book: AddressBook) -> [ProjectHosts.Peer] {
        var peers: [ProjectHosts.Peer] = []
        for record in book.records.values {
            guard let service = record.service, let svc = project.file.services[service] else { continue }
            var aliases: [String: [String]] = [:]
            for declared in svc.networks?.names ?? [] {
                let names = svc.networks?.aliases(on: declared) ?? []
                if !names.isEmpty { aliases[translator.networkName(declared)] = names }
            }
            var addresses: [String: String] = [:]
            for attachment in record.networks {
                if let ipv4 = attachment.ipv4 { addresses[attachment.network] = ipv4 }
            }
            let names = record.id == service ? [service] : [service, record.id]
            peers.append(.init(names: names, aliases: aliases, addresses: addresses))
        }
        return peers
    }

    /// Render and write the hosts file for a service from the current address
    /// book, returning its host path for `--volume`. Nothing is written during a
    /// dry run.
    private func writeHosts(service name: String, _ svc: Service, book: AddressBook) throws -> String {
        let cname = translator.containerName(service: name, declared: svc.container_name)
        let networks = runtimeNetworks(svc)
        let content = ProjectHosts.render(
            networks: networks, peers: peers(in: book),
            gateway: networks.first.flatMap { book.gateways[$0] },
            extraHosts: svc.extra_hosts?.entries ?? [],
            hostEntries: book.hostEntries)
        if !runner.dryRun { try hosts.write(content, for: cname) }
        return hosts.path(for: cname)
    }

    /// Record a just-started container's addresses and rewrite the hosts files of
    /// every running project container that shares a network with it (including
    /// its own, which now gains a self entry).
    private func noteStarted(_ cname: String, book: inout AddressBook) async throws {
        if runner.dryRun { return }
        let (status, out) = try await runner.capture(["inspect", cname])
        guard status == 0, let record = try? ContainerRecord.decodeList(out).first else {
            warn("could not inspect '\(cname)'; other services will not resolve it by name")
            return
        }
        book.note(record)

        let touched = Set(record.networks.map(\.network))
        for peer in book.records.values where peer.isRunning {
            guard let service = peer.service, let svc = project.file.services[service],
                !touched.isDisjoint(with: runtimeNetworks(svc))
            else { continue }
            _ = try writeHosts(service: service, svc, book: book)
        }
    }

    /// Project containers whose service label is missing or no longer declared.
    private func orphans(in records: [ContainerRecord]) -> [ContainerRecord] {
        records.filter { record in
            guard let service = record.service else { return true }
            return project.file.services[service] == nil
        }
    }

    private func remove(orphans: [ContainerRecord]) async throws {
        for orphan in orphans.sorted(by: { $0.id < $1.id }) {
            info("Removing orphan \(orphan.id) ...")
            try await runner.runSilently(["stop", orphan.id])
            try await runner.runSilently(["delete", "--force", orphan.id])
        }
    }

    private func ensureNetworks() async throws {
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
            try await runner.runSilently(args)
        }
    }

    private func ensureVolumes() async throws {
        // Declared top-level named volumes.
        var names = Set<String>()
        for (declared, spec) in project.file.volumes ?? [:] {
            if spec?.external?.isExternal == true { continue }
            names.insert(declared)
        }
        for name in names.sorted() {
            // Idempotent: an existing volume is reused.
            try await runner.runSilently(["volume", "create", translator.volumeName(name)])
        }
    }

    private func warnUnsupported(name: String, svc: Service) {
        if svc.restart != nil {
            warn("service '\(name)': 'restart' is recorded as a label but not enforced by container")
        }
        if svc.privileged == true {
            warn("service '\(name)': 'privileged' has no container equivalent and is ignored")
        }
        // Popular fields `container` cannot express — decoded so the file parses,
        // but flagged so the gap is visible rather than silently dropped.
        var ignored: [String] = []
        if svc.hostname != nil { ignored.append("hostname") }
        if svc.network_mode != nil { ignored.append("network_mode") }
        if svc.devices != nil { ignored.append("devices") }
        if svc.sysctls != nil { ignored.append("sysctls") }
        if svc.security_opt != nil { ignored.append("security_opt") }
        if svc.stop_signal != nil { ignored.append("stop_signal") }
        if svc.stop_grace_period != nil { ignored.append("stop_grace_period") }
        if svc.gpus != nil { ignored.append("gpus") }
        if !ignored.isEmpty {
            warn("service '\(name)': \(ignored.joined(separator: ", ")) "
                + "\(ignored.count == 1 ? "has" : "have") no container equivalent and "
                + "\(ignored.count == 1 ? "is" : "are") ignored")
        }

        // Ports container can't publish (container-port-only; no host port).
        for port in svc.ports ?? [] where translator.publishArgument(port) == nil {
            let text: String
            switch port {
            case .short(let s): text = s
            case .long(let p): text = String(p.target)
            }
            warn("service '\(name)': port '\(text)' publishes only a container port; "
                + "container cannot auto-assign a host port, skipping")
        }

        // Build fields `container build` cannot express.
        var build: [String] = []
        if svc.build?.long?.ssh != nil { build.append("build.ssh") }
        if svc.build?.long?.network != nil { build.append("build.network") }
        if svc.build?.long?.cache_from != nil { build.append("build.cache_from") }
        if !build.isEmpty {
            warn("service '\(name)': \(build.joined(separator: ", ")) "
                + "\(build.count == 1 ? "is" : "are") not supported by container build and "
                + "\(build.count == 1 ? "is" : "are") ignored")
        }
    }
}
