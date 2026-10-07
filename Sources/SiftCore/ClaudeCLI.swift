//
// Copyright © Agulhas Labs
//

import Foundation

/// The `claude` on the PATH `environment` names, run with `HOME` set to the home every other path was resolved from, so the config it writes is the one read back.
public struct ClaudeCLI: ClaudeMcpRunner {
    /// The environment `claude` is looked up in and handed, never this process's own unless the caller passes it.
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    public func run(_ arguments: [String]) throws -> SimulatorAccessibility.Output? {
        guard let claude = InvokedBinary.onPath("claude", environment: environment) else { return nil }
        var child = environment
        child["HOME"] = SiftPaths.userHome(environment: environment).path
        return try SimulatorAccessibility.spawn(claude, arguments, deadline: 60, environment: child)
    }
}
