//
// Copyright © Agulhas Labs
//

import Foundation

/// The live runner: the first `codex` on the PATH `environment` names, run with that environment and `CODEX_HOME` set to the home, so the configuration it edits sits beside the hooks the install wrote.
public struct CodexCLI: CodexMcpRunner {
    /// The environment `codex` is looked up in and handed, never this process's own unless the caller passes it.
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func run(_ arguments: [String], home: URL) throws -> SimulatorAccessibility.Output? {
        guard let codex = InvokedBinary.onPath("codex", environment: environment) else { return nil }
        var child = environment
        child["CODEX_HOME"] = home.path
        return try SimulatorAccessibility.spawn(codex, arguments, deadline: 60, environment: child)
    }
}
