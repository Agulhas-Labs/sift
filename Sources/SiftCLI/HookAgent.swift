//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftMCP

/// The harness a hook command answers, named by the `--agent` its registration carries and never sniffed from the payload.
///
/// On Cursor a response that does not match the schema can block the call, so a protocol guessed wrongly would make a call unavailable; the registration says which protocol it speaks instead.
enum HookAgent: String, CaseIterable, ExpressibleByArgument {
    case claude
    case cursor
}

extension HookAgent {
    /// The grep this harness's shell runs, which an in-place answer to a search models: Claude Code's `ugrep`, or the system's own in Cursor's shell and in Codex's, which calls the Claude Code registration with a `payload` carrying the `turn_id` no Claude Code payload has.
    func shellGrep(payload: [String: Any]) -> ShellGrep.Program {
        self == .cursor || payload["turn_id"] != nil ? .system : .ugrep
    }
}
