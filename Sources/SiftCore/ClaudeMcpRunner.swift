//
// Copyright © Agulhas Labs
//

import Foundation

/// Who runs `claude mcp` for the install, so a test never runs the real `claude` against the real config.
public protocol ClaudeMcpRunner: Sendable {
    /// Runs `claude` with `arguments`, each passed as one argument and never through a shell; `nil` when there is no `claude` to run.
    func run(_ arguments: [String]) throws -> SimulatorAccessibility.Output?
}
