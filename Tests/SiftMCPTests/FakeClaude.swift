//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A `claude` that records every run and keeps the user-scope server in a scratch `.claude.json` the way `claude mcp add` and `remove` would, so a read-back of that file sees what it did.
final class FakeClaude: ClaudeMcpRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let present: Bool
    private let config: URL
    /// What `add` answers: `true` writes the server and succeeds, `false` fails and writes nothing.
    private let addSucceeds: Bool
    /// Whether a successful `add` writes the server into the config at all.
    private let addWrites: Bool
    private var recorded: [[String]] = []

    init(config: URL, present: Bool = true, addSucceeds: Bool = true, addWrites: Bool = true) {
        self.config = config
        self.present = present
        self.addSucceeds = addSucceeds
        self.addWrites = addWrites
    }

    /// Every run's arguments, in order.
    var calls: [[String]] {
        lock.withLock { recorded }
    }

    func run(_ arguments: [String]) throws -> SimulatorAccessibility.Output? {
        guard present else { return nil }
        return lock.withLock {
            recorded.append(arguments)
            var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: config))) as? [String: Any] ?? [:]
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            switch Array(arguments.prefix(2)) {
            case ["mcp", "add"]:
                guard addSucceeds else {
                    return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "add refused")
                }
                guard addWrites else { return SimulatorAccessibility.Output(succeeded: true, standardOutput: "Added") }
                let command = arguments.drop { $0 != "--" }.dropFirst()
                servers["sift"] = ["type": "stdio", "command": command.first ?? "", "args": Array(command.dropFirst())]
            case ["mcp", "remove"]:
                servers.removeValue(forKey: "sift")
            default:
                return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "unexpected")
            }
            object["mcpServers"] = servers
            try? JSONSerialization.data(withJSONObject: object).write(to: config)
            return SimulatorAccessibility.Output(succeeded: true, standardOutput: "done")
        }
    }
}
