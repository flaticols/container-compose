//===----------------------------------------------------------------------===//
// Typed model of a Compose file.
//
// This is intentionally a pragmatic subset of the compose-spec
// (https://github.com/compose-spec/compose-spec). Fields that `container`
// cannot yet express are still decoded (so files parse) but may be ignored at
// translation time — see Translator for what is actually applied.
//===----------------------------------------------------------------------===//

import Foundation
import Yams

public struct ComposeFile: Decodable, Sendable {
    public var name: String?
    public var services: [String: Service]
    public var networks: [String: NetworkSpec?]?
    public var volumes: [String: VolumeSpec?]?

    /// Decode a Compose file from a YAML string.
    public static func parse(yaml: String) throws -> ComposeFile {
        try YAMLDecoder().decode(ComposeFile.self, from: yaml)
    }
}

public struct Service: Decodable, Sendable {
    public var image: String?
    public var build: BuildSpec?
    public var command: StringOrList?
    public var entrypoint: StringOrList?
    public var environment: KeyValuePairs?
    public var env_file: StringOrList?
    public var ports: [PortMapping]?
    public var expose: [ComposeScalar]?
    public var volumes: [VolumeMount]?
    public var networks: NameListOrMap?
    public var depends_on: DependsOn?
    public var labels: KeyValuePairs?
    public var working_dir: String?
    public var user: String?
    public var container_name: String?
    public var restart: String?
    public var cap_add: [String]?
    public var cap_drop: [String]?
    public var dns: StringOrList?
    public var tmpfs: StringOrList?
    public var read_only: Bool?
    public var `init`: Bool?
    public var platform: String?
    public var privileged: Bool?
    public var deploy: Deploy?
    public var cpus: ComposeScalar?
    public var mem_limit: String?
    public var healthcheck: Healthcheck?
}

/// `depends_on` as a plain list, or a map of `service -> { condition }`.
public enum DependsOn: Decodable, Sendable {
    case list([String])
    case map([String: Dependency])

    public struct Dependency: Decodable, Sendable {
        public var condition: String?  // service_started | service_healthy | service_completed_successfully
        public var required: Bool?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: Dependency].self))
        }
    }

    public var names: [String] {
        switch self {
        case .list(let a): return a
        case .map(let m): return m.keys.sorted()
        }
    }

    /// Declared start condition for a dependency (defaults to `service_started`).
    public func condition(for name: String) -> String {
        if case .map(let m) = self, let c = m[name]?.condition { return c }
        return "service_started"
    }
}

/// `build: ./dir` or a long-form build block.
public enum BuildSpec: Decodable, Sendable {
    case context(String)
    case long(LongBuild)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .context(s)
        } else {
            self = .long(try c.decode(LongBuild.self))
        }
    }

    public var contextPath: String {
        switch self {
        case .context(let s): return s
        case .long(let b): return b.context ?? "."
        }
    }

    public var dockerfile: String? {
        if case .long(let b) = self { return b.dockerfile }
        return nil
    }

    public var target: String? {
        if case .long(let b) = self { return b.target }
        return nil
    }

    public var args: KeyValuePairs? {
        if case .long(let b) = self { return b.args }
        return nil
    }
}

public struct LongBuild: Decodable, Sendable {
    public var context: String?
    public var dockerfile: String?
    public var args: KeyValuePairs?
    public var target: String?
}

/// `ports` entry: `"8080:80"`, `8080`, or a long-form mapping.
public enum PortMapping: Decodable, Sendable {
    case short(String)
    case long(LongPort)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else if let i = try? c.decode(Int.self) {
            self = .short(String(i))
        } else {
            self = .long(try c.decode(LongPort.self))
        }
    }

    /// Render as a `container --publish` argument.
    public var publishArgument: String {
        switch self {
        case .short(let s):
            return s
        case .long(let p):
            var lhs = ""
            if let host = p.host_ip { lhs += "\(host):" }
            if let published = p.published { lhs += "\(published.stringValue):" }
            var arg = "\(lhs)\(p.target)"
            if let proto = p.`protocol` { arg += "/\(proto)" }
            return arg
        }
    }
}

public struct LongPort: Decodable, Sendable {
    public var target: Int
    public var published: ComposeScalar?
    public var host_ip: String?
    public var `protocol`: String?
    public var mode: String?
}

/// `volumes` entry: `"name:/path"`, `"/host:/ctr:ro"`, or a long-form mapping.
public enum VolumeMount: Decodable, Sendable {
    case short(String)
    case long(LongVolume)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .short(s)
        } else {
            self = .long(try c.decode(LongVolume.self))
        }
    }
}

public struct LongVolume: Decodable, Sendable {
    public var type: String?  // volume | bind | tmpfs
    public var source: String?
    public var target: String
    public var read_only: Bool?
}

public struct Deploy: Decodable, Sendable {
    public var resources: Resources?

    public struct Resources: Decodable, Sendable {
        public var limits: Limits?

        public struct Limits: Decodable, Sendable {
            public var cpus: ComposeScalar?
            public var memory: String?
        }
    }
}

public struct Healthcheck: Decodable, Sendable {
    public var test: StringOrList?
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var start_period: String?
    public var disable: Bool?
}

public struct NetworkSpec: Decodable, Sendable {
    public var driver: String?
    public var name: String?
    public var external: ExternalRef?
    public var `internal`: Bool?
    public var ipam: IPAM?

    public struct IPAM: Decodable, Sendable {
        public var config: [IPAMConfig]?

        public struct IPAMConfig: Decodable, Sendable {
            public var subnet: String?
        }
    }

    /// First declared subnet, if any.
    public var subnet: String? { ipam?.config?.first?.subnet }
}

public struct VolumeSpec: Decodable, Sendable {
    public var driver: String?
    public var name: String?
    public var external: ExternalRef?
    public var labels: KeyValuePairs?
}
