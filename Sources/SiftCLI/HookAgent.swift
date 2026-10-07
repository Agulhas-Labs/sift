//
// Copyright © Agulhas Labs
//

import ArgumentParser

/// The harness a hook command answers, named by the `--agent` its registration carries and never sniffed from the payload.
///
/// On Cursor a response that does not match the schema can block the call, so a protocol guessed wrongly would make a call unavailable; the registration says which protocol it speaks instead.
enum HookAgent: String, CaseIterable, ExpressibleByArgument {
    case claude
    case cursor
}
