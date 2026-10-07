//
// Copyright © Agulhas Labs
//

import Foundation

/// An agent `sift install` can install into, spelled as its `--agent` value.
public enum InstallAgent: String, CaseIterable, Sendable {
    case claude
    case cursor
    case codex

    /// The agent's name as a person reads it.
    public var harness: String {
        switch self {
        case .claude:
            "Claude Code"
        case .cursor:
            "Cursor"
        case .codex:
            "Codex"
        }
    }
}
