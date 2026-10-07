//
// Copyright © Agulhas Labs
//

import Foundation

/// Runs `codex` for the MCP half of `install-hook --agent codex`, injected so a test never runs the real one against a real Codex home.
public protocol CodexMcpRunner: Sendable {
    /// Runs `codex` with `arguments`, each passed as one argument and never through a shell, against the Codex home `home`; `nil` when there is no `codex` to run.
    func run(_ arguments: [String], home: URL) throws -> SimulatorAccessibility.Output?
}
