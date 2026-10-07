//
// Copyright © Agulhas Labs
//

import Foundation

/// The CLI's sanctioned output path: stdout is the product, stderr the complaint channel.
///
/// Deliberately avoids the global printing helper — the repo bans it as a logging habit, and a CLI should be explicit about which stream it writes anyway (the MCP face makes stdout discipline load-bearing).
struct StandardStreams {
    /// One-time SIGPIPE suppression so `sift … | head` ends quietly instead of dying at the write syscall.
    private static let ignoreSigpipe: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    static func emit(_ text: String) {
        _ = ignoreSigpipe
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    /// Bytes straight through, newline and all: `run`'s passthrough must not reshape what it forwards.
    static func emitRaw(_ data: Data) {
        _ = ignoreSigpipe
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    static func emitError(_ text: String) {
        _ = ignoreSigpipe
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}
