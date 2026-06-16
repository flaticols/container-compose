//===----------------------------------------------------------------------===//
// Health gating for `depends_on: condition: service_healthy`.
//
// `container` has no native healthcheck, so we run the Compose-defined
// `healthcheck.test` ourselves via `container exec` in a poll loop, honoring
// interval / retries / start_period.
//===----------------------------------------------------------------------===//

import Foundation

public struct HealthChecker: Sendable {
    public let runner: ContainerRunner

    public init(runner: ContainerRunner) {
        self.runner = runner
    }

    /// Block until the container's healthcheck passes, or throw after the
    /// configured number of retries is exhausted.
    public func waitHealthy(container: String, health: Healthcheck) throws {
        guard let test = health.test, let execArgs = Self.execArguments(for: test) else {
            return  // no test / NONE => nothing to gate on
        }

        let interval = Self.seconds(health.interval) ?? 30
        let startPeriod = Self.seconds(health.start_period) ?? 0
        let retries = max(health.retries ?? 3, 1)

        if startPeriod > 0, !runner.dryRun {
            Thread.sleep(forTimeInterval: startPeriod)
        }

        var attempt = 0
        while true {
            attempt += 1
            let (status, _) = try runner.capture(["exec", container] + execArgs)
            if status == 0 { return }
            if attempt >= retries { throw ComposeError.dependencyUnhealthy(container) }
            if !runner.dryRun { Thread.sleep(forTimeInterval: interval) }
        }
    }

    /// Translate a Compose `healthcheck.test` into `container exec` arguments.
    /// Returns nil if the check is disabled (`["NONE"]`).
    public static func execArguments(for test: StringOrList) -> [String]? {
        switch test {
        case .string(let s):
            return ["/bin/sh", "-c", s]
        case .list(let arr):
            guard let head = arr.first else { return nil }
            switch head {
            case "NONE":
                return nil
            case "CMD":
                return Array(arr.dropFirst())
            case "CMD-SHELL":
                return ["/bin/sh", "-c", arr.dropFirst().joined(separator: " ")]
            default:
                return arr  // bare argv form
            }
        }
    }

    /// Parse a Go-style duration ("30s", "1m30s", "500ms", "1h") to seconds.
    /// A bare number is treated as seconds.
    static func seconds(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        if let plain = Double(text) { return plain }

        var total = 0.0
        var number = ""
        var unit = ""

        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "ns": total += value / 1_000_000_000
            case "us", "µs": total += value / 1_000_000
            case "ms": total += value / 1000
            case "s", "": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            default: return false
            }
            number = ""
            unit = ""
            return true
        }

        for ch in text {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty {
                    if !flush() { return nil }
                }
                number.append(ch)
            } else {
                unit.append(ch)
            }
        }
        if !number.isEmpty || !unit.isEmpty {
            if !flush() { return nil }
        }
        return total
    }
}
