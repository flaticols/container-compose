import Foundation

/// Per-container `/etc/hosts` files that give a project Compose-style name
/// resolution on Apple `container`, which has no service DNS of its own.
///
/// Each service container bind-mounts its own file over `/etc/hosts`. The file
/// lists every project container reachable on a shared network under its service
/// name, container name, and declared network aliases, plus `host.docker.internal`
/// (the network gateway, which is the Mac) and the service's `extra_hosts`.
///
/// Files are rewritten in place as containers start. The guest bind mount pins
/// the host file's inode, so an atomic replace would detach the mount, whereas an
/// in-place rewrite becomes visible inside the container within about a second.
public struct ProjectHosts: Sendable {
    /// Directory holding one file per container.
    public let directory: URL

    /// Files are padded with trailing newlines to a multiple of this size. The
    /// guest caches file attributes for about a second, and a rewrite that grows
    /// the file is read truncated at the old size during that window; a same-size
    /// rewrite is read whole (either the old or the new consistent contents).
    public static let sizeQuantum = 4096

    /// Names that resolve to the Mac from inside a container.
    public static let hostNames = ["host.docker.internal", "gateway.docker.internal"]
    /// The `extra_hosts` address keyword Docker maps to the host gateway.
    public static let hostGatewayKeyword = "host-gateway"

    /// Create a manager for files under `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The default state root: `$XDG_STATE_HOME/container-compose`, or
    /// `~/.local/state/container-compose`. Kept outside the temp directory so a
    /// mounted file is never cleaned up underneath a long-running container, and
    /// free of spaces so it is safe to pass to `--volume`.
    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        }
        return base.appendingPathComponent("container-compose", isDirectory: true)
    }

    /// Host path of the file mounted into `container`.
    public func path(for container: String) -> String {
        directory.appendingPathComponent(container).path
    }

    /// A project container's resolvable names and its address on each network.
    public struct Peer: Sendable, Equatable {
        /// Names valid on every network: the service name and the container name.
        public var names: [String]
        /// Compose `networks.<name>.aliases`, keyed by runtime network name.
        public var aliases: [String: [String]]
        /// IPv4 address keyed by runtime network name.
        public var addresses: [String: String]

        public init(names: [String], aliases: [String: [String]] = [:], addresses: [String: String]) {
            self.names = names
            self.aliases = aliases
            self.addresses = addresses
        }
    }

    /// Render the hosts file for a container attached to `networks`.
    ///
    /// - Parameters:
    ///   - networks: the container's runtime network names, primary first.
    ///   - peers: project containers whose addresses are known (including this
    ///     one, once it has started). Peers on no shared network are omitted.
    ///   - gateway: the gateway of the primary network; `nil` omits the host
    ///     entries and any `host-gateway` extra host.
    ///   - extraHosts: Compose `extra_hosts` entries (`host:ip` or `host=ip`).
    ///   - hostEntries: emit ``hostNames``. Pass `false` when the user has
    ///     registered `host.docker.internal` with `container system dns`, so the
    ///     file does not shadow that DNS answer.
    public static func render(
        networks: [String], peers: [Peer], gateway: String?,
        extraHosts: [String] = [], hostEntries: Bool = true
    ) -> String {
        var lines = ["127.0.0.1 localhost", "::1 localhost ip6-localhost ip6-loopback"]
        for peer in peers.sorted(by: { ($0.names.first ?? "") < ($1.names.first ?? "") }) {
            for network in networks {
                guard let address = peer.addresses[network] else { continue }
                var seen = Set<String>()
                let names = (peer.names + (peer.aliases[network] ?? [])).filter { seen.insert($0).inserted }
                lines.append("\(address) \(names.joined(separator: " "))")
            }
        }
        if let gateway, hostEntries {
            lines.append("\(gateway) \(hostNames.joined(separator: " "))")
        }
        for entry in extraHosts {
            guard let (host, address) = parseExtraHost(entry) else { continue }
            if address == hostGatewayKeyword {
                if let gateway { lines.append("\(gateway) \(host)") }
            } else {
                lines.append("\(address) \(host)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Split an `extra_hosts` entry into host and address. Docker accepts
    /// `host:ip` and `host=ip`; the split is on the first separator because IPv6
    /// addresses contain colons, and brackets around an IPv6 address are dropped.
    static func parseExtraHost(_ entry: String) -> (host: String, address: String)? {
        guard let separator = entry.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
        let host = entry[..<separator].trimmingCharacters(in: .whitespaces)
        var address = entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        guard !host.isEmpty, !address.isEmpty else { return nil }
        return (host, address)
    }

    /// Write `content` to the container's file in place, creating it if needed
    /// and padding it to a multiple of ``sizeQuantum``.
    public func write(_ content: String, for container: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(path(for: container), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Self.padded(Data(content.utf8)))
        try handle.close()
    }

    /// `data` followed by newlines up to the next multiple of ``sizeQuantum``.
    static func padded(_ data: Data) -> Data {
        let remainder = data.count % sizeQuantum
        guard remainder != 0 else { return data }
        return data + Data(repeating: UInt8(ascii: "\n"), count: sizeQuantum - remainder)
    }

    /// Delete the project's hosts files, and the project directory if that
    /// leaves it empty. Containers that still mount a file keep its last
    /// contents until they are recreated.
    public func remove() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        try fm.removeItem(at: directory)
        let parent = directory.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fm.removeItem(at: parent)
        }
    }
}
