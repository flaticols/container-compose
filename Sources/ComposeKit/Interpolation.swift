//===----------------------------------------------------------------------===//
// Compose variable interpolation and `.env` file loading.
//
// Interpolation runs on the raw YAML text before decoding (the pragmatic
// approach used by most Compose reimplementations). Supported forms:
//
//   $VAR        ${VAR}
//   ${VAR:-def} default if VAR is unset OR empty
//   ${VAR-def}  default if VAR is unset
//   ${VAR:+rep} rep if VAR is set AND non-empty
//   ${VAR+rep}  rep if VAR is set
//   ${VAR:?err} error if VAR is unset OR empty
//   ${VAR?err}  error if VAR is unset
//   $$          literal '$'
//===----------------------------------------------------------------------===//

import Foundation

public enum Interpolator {
    /// Expand `$VAR` / `${VAR...}` references in `text` using `variables`.
    public static func expand(_ text: String, variables: [String: String]) throws -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        let n = chars.count

        func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
        func isIdent(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

        while i < n {
            let c = chars[i]
            guard c == "$" else {
                out.append(c)
                i += 1
                continue
            }
            // Lone trailing '$'
            guard i + 1 < n else {
                out.append("$")
                i += 1
                continue
            }
            let next = chars[i + 1]
            if next == "$" {
                out.append("$")  // escaped
                i += 2
            } else if next == "{" {
                // Read until matching '}'.
                var j = i + 2
                var body = ""
                while j < n && chars[j] != "}" {
                    body.append(chars[j])
                    j += 1
                }
                guard j < n else {
                    throw ComposeError.interpolation("unterminated '${' in Compose file")
                }
                out += try resolveBraced(body, variables: variables)
                i = j + 1
            } else if isIdentStart(next) {
                var j = i + 1
                var name = ""
                while j < n && isIdent(chars[j]) {
                    name.append(chars[j])
                    j += 1
                }
                out += variables[name] ?? ""
                i = j
            } else {
                out.append("$")  // not a reference
                i += 1
            }
        }
        return out
    }

    private static func resolveBraced(_ body: String, variables: [String: String]) throws -> String {
        // Split NAME from an optional operator + word.
        let operators = [":-", ":+", ":?", "-", "+", "?"]  // longest first
        for op in operators {
            if let range = body.range(of: op) {
                let name = String(body[body.startIndex..<range.lowerBound])
                // The remaining could contain another operator char; take the rest verbatim.
                let word = String(body[range.upperBound...])
                return try apply(op: op, name: name, word: word, variables: variables)
            }
        }
        return variables[body] ?? ""
    }

    private static func apply(op: String, name: String, word: String, variables: [String: String]) throws -> String {
        let value = variables[name]
        let isEmpty = (value ?? "").isEmpty
        switch op {
        case ":-": return isEmpty ? word : value!
        case "-": return value ?? word
        case ":+": return (value != nil && !isEmpty) ? word : ""
        case "+": return value != nil ? word : ""
        case ":?":
            if isEmpty { throw ComposeError.requiredVariable(name, word) }
            return value!
        case "?":
            if value == nil { throw ComposeError.requiredVariable(name, word) }
            return value!
        default: return value ?? ""
        }
    }
}

/// Parses `.env`-style files: `KEY=VALUE` lines, `export` prefix, `#` comments,
/// surrounding quotes, and trailing inline comments on unquoted values.
public enum EnvFile {
    public static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            result[key] = value
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        // Unquoted: strip an inline comment that is preceded by whitespace.
        if let hash = value.range(of: " #") {
            return String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
