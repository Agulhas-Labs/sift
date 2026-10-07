//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A `codex` that keeps one server named `sift` in memory and answers `mcp get`, `add` and `remove` as the real one did when probed, recording every call.
final class FakeCodex: CodexMcpRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let present: Bool
    private let getError: String?
    private var recorded: [Call] = []
    private var registered: (command: String, arguments: [String])?

    /// A `codex` on PATH (`present`) holding `server`, whose `get` fails with `getError` when one is given.
    init(present: Bool = true, server: (command: String, arguments: [String])? = nil, getError: String? = nil) {
        self.present = present
        registered = server
        self.getError = getError
    }

    /// Every run, in order.
    var calls: [Call] {
        lock.withLock { recorded }
    }

    /// The server named `sift`, as the last run left it.
    var server: (command: String, arguments: [String])? {
        lock.withLock { registered }
    }

    func run(_ arguments: [String], home: URL) throws -> SimulatorAccessibility.Output? {
        guard present else { return nil }
        return lock.withLock {
            recorded.append(Call(arguments: arguments, home: home.path))
            switch Array(arguments.prefix(2)) {
            case ["mcp", "get"]:
                if let getError {
                    return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: getError)
                }
                guard let registered else {
                    return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Error: No MCP server named 'sift' found.")
                }
                let shown: [String: Any] = ["name": "sift", "transport": ["type": "stdio", "command": registered.command, "args": registered.arguments]]
                let json = (try? JSONSerialization.data(withJSONObject: shown)).map { String(bytes: $0, encoding: .utf8) ?? "" } ?? ""
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: json)
            case ["mcp", "add"]:
                let command = arguments.drop { $0 != "--" }.dropFirst()
                registered = (command.first ?? "", Array(command.dropFirst()))
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "Added global MCP server 'sift'.")
            case ["mcp", "remove"]:
                registered = nil
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "Removed global MCP server 'sift'.")
            default:
                return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "unexpected")
            }
        }
    }
}

extension FakeCodex {
    /// One run: the arguments exactly as passed and the Codex home it was pointed at.
    struct Call: Equatable {
        let arguments: [String]
        let home: String
    }
}
