//===----------------------------------------------------------------------===//
// Polymorphic decoding helpers for the Compose spec.
//
// The Compose file format is loose: many fields accept either a scalar, a
// sequence, or a mapping. These small wrappers normalize those shapes so the
// rest of the code can treat them uniformly.
//===----------------------------------------------------------------------===//

import Foundation

/// A YAML scalar that may appear as a string, integer, double, or bool.
/// Normalized to its string form (e.g. `0.5`, `true`, `8080`).
public struct ComposeScalar: Decodable, Sendable, Equatable {
    public let stringValue: String

    public init(_ value: String) { self.stringValue = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.stringValue = ""
        } else if let s = try? c.decode(String.self) {
            self.stringValue = s
        } else if let b = try? c.decode(Bool.self) {
            self.stringValue = b ? "true" : "false"
        } else if let i = try? c.decode(Int.self) {
            self.stringValue = String(i)
        } else if let d = try? c.decode(Double.self) {
            self.stringValue = String(d)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported scalar value")
        }
    }
}

/// A field that is either a single string or a list of strings
/// (e.g. `command`, `entrypoint`, `dns`, `env_file`).
public enum StringOrList: Decodable, Sendable, Equatable {
    case string(String)
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    /// Flattened list form. A single string becomes a one-element list.
    public var values: [String] {
        switch self {
        case .string(let s): return [s]
        case .list(let a): return a
        }
    }
}

/// A `key=value` collection that is either a mapping or a `KEY=VALUE` list
/// (e.g. `environment`, `labels`, `build.args`).
public enum KeyValuePairs: Decodable, Sendable, Equatable {
    case map([String: ComposeScalar?])
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: ComposeScalar?].self))
        }
    }

    /// Resolve to `KEY=VALUE` strings. Entries with no value are filled from
    /// `hostEnv` (Compose's variable pass-through), or dropped if absent.
    public func pairs(hostEnv: [String: String] = [:]) -> [String] {
        switch self {
        case .list(let arr):
            return arr.compactMap { item in
                if item.contains("=") { return item }
                if let v = hostEnv[item] { return "\(item)=\(v)" }
                return nil
            }
        case .map(let dict):
            return dict.sorted { $0.key < $1.key }.compactMap { key, value in
                if let value, !value.stringValue.isEmpty {
                    return "\(key)=\(value.stringValue)"
                }
                if let v = hostEnv[key] { return "\(key)=\(v)" }
                return nil
            }
        }
    }
}

/// A name->config mapping or a plain list of names (e.g. `depends_on`,
/// service-level `networks`). We only need the set of names for orchestration.
public enum NameListOrMap: Decodable, Sendable, Equatable {
    case list([String])
    case map([String: AnyConfig])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([String].self) {
            self = .list(arr)
        } else {
            self = .map(try c.decode([String: AnyConfig].self))
        }
    }

    public var names: [String] {
        switch self {
        case .list(let a): return a
        case .map(let m): return m.keys.sorted()
        }
    }
}

/// Opaque, ignored sub-config. Lets us accept (and skip) the body of
/// `depends_on: {db: {condition: ...}}` or `networks: {net: {aliases: ...}}`
/// without modelling every nested field yet.
public struct AnyConfig: Decodable, Sendable, Equatable {
    public init(from decoder: Decoder) throws {}
}

/// `external: true` or `external: { name: foo }`.
public struct ExternalRef: Decodable, Sendable, Equatable {
    public let isExternal: Bool
    public let name: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self.isExternal = b
            self.name = nil
        } else if let obj = try? c.decode([String: String].self) {
            self.isExternal = true
            self.name = obj["name"]
        } else {
            self.isExternal = false
            self.name = nil
        }
    }
}
