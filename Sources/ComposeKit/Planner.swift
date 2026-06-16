//===----------------------------------------------------------------------===//
// Resolve service start order from `depends_on` via a topological sort.
//
// NOTE: only ordering is enforced. Compose's `condition: service_healthy`
// gating is not yet applied — see Translator/Orchestrator TODOs.
//===----------------------------------------------------------------------===//

public enum Planner {
    /// Return service names in dependency order (dependencies first).
    /// Throws `ComposeError.dependencyCycle` on a cycle.
    public static func startOrder(_ services: [String: Service]) throws -> [String] {
        var visited = Set<String>()
        var inProgress = Set<String>()
        var order: [String] = []

        func visit(_ name: String) throws {
            if visited.contains(name) { return }
            if inProgress.contains(name) { throw ComposeError.dependencyCycle(name) }
            inProgress.insert(name)
            let deps = services[name]?.depends_on?.names ?? []
            for dep in deps where services[dep] != nil {
                try visit(dep)
            }
            inProgress.remove(name)
            visited.insert(name)
            order.append(name)
        }

        for name in services.keys.sorted() {
            try visit(name)
        }
        return order
    }
}
