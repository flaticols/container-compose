import Foundation

/// A container as reported by `container list --format json` or
/// `container inspect`, reduced to what the orchestrator needs: identity, the
/// Compose bookkeeping labels, lifecycle state, and per-network addressing.
///
/// Only these keys are decoded; everything else in the CLI's JSON is ignored so
/// the schema can grow without breaking the decoder.
public struct ContainerRecord: Decodable, Sendable, Equatable {
    /// One network attachment, as reported under `status.networks`.
    public struct Attachment: Decodable, Sendable, Equatable {
        /// The network name.
        public var network: String
        /// The IPv4 address as printed by the CLI, with its prefix length
        /// (`192.168.64.2/24`).
        public var ipv4Address: String?
        /// The network's IPv4 gateway, which is also the Mac host.
        public var ipv4Gateway: String?

        public init(network: String, ipv4Address: String? = nil, ipv4Gateway: String? = nil) {
            self.network = network
            self.ipv4Address = ipv4Address
            self.ipv4Gateway = ipv4Gateway
        }

        /// The IPv4 address without its prefix length.
        public var ipv4: String? {
            guard let ipv4Address else { return nil }
            return String(ipv4Address.prefix { $0 != "/" })
        }
    }

    /// The container ID, which `container` equates with its `--name`.
    public var id: String
    /// Labels set at `container run` time.
    public var labels: [String: String]
    /// Lifecycle state as printed by the CLI (`running`, `stopped`, ...).
    public var state: String?
    /// Network attachments; empty until the container has started.
    public var networks: [Attachment]

    public init(
        id: String, labels: [String: String] = [:], state: String? = nil,
        networks: [Attachment] = []
    ) {
        self.id = id
        self.labels = labels
        self.state = state
        self.networks = networks
    }

    private enum CodingKeys: String, CodingKey { case id, configuration, status }
    private enum ConfigurationKeys: String, CodingKey { case labels }
    private enum StatusKeys: String, CodingKey { case state, networks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let configuration = try c.nestedContainer(keyedBy: ConfigurationKeys.self, forKey: .configuration)
        labels = try configuration.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        if let status = try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .status) {
            state = try status.decodeIfPresent(String.self, forKey: .state)
            networks = try status.decodeIfPresent([Attachment].self, forKey: .networks) ?? []
        } else {
            state = nil
            networks = []
        }
    }

    /// The Compose project this container belongs to, if container-compose created it.
    public var project: String? { labels[ContainerTranslator.projectLabel] }
    /// The Compose service this container runs, if container-compose created it.
    public var service: String? { labels[ContainerTranslator.serviceLabel] }
    /// Whether the CLI reports the container as running.
    public var isRunning: Bool { state == "running" }

    /// Decode the JSON array printed by `container list --format json` or
    /// `container inspect`. Blank input (a dry run) yields an empty list.
    public static func decodeList(_ json: String) throws -> [ContainerRecord] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try JSONDecoder().decode([ContainerRecord].self, from: Data(trimmed.utf8))
    }
}

/// A network as reported by `container network inspect`, reduced to its name
/// and IPv4 gateway.
public struct NetworkRecord: Decodable, Sendable, Equatable {
    /// The network name.
    public var id: String
    /// The IPv4 gateway, which is also the Mac host as seen from the network.
    public var ipv4Gateway: String?

    public init(id: String, ipv4Gateway: String? = nil) {
        self.id = id
        self.ipv4Gateway = ipv4Gateway
    }

    private enum CodingKeys: String, CodingKey { case id, status }
    private enum StatusKeys: String, CodingKey { case ipv4Gateway }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let status = try? c.nestedContainer(keyedBy: StatusKeys.self, forKey: .status)
        ipv4Gateway = try status?.decodeIfPresent(String.self, forKey: .ipv4Gateway)
    }

    /// Decode the JSON array printed by `container network inspect`. Blank
    /// input yields an empty list.
    public static func decodeList(_ json: String) throws -> [NetworkRecord] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try JSONDecoder().decode([NetworkRecord].self, from: Data(trimmed.utf8))
    }
}
