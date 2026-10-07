//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Where a command's answer is written: the standard streams in every real invocation, and a recorder in a test.
///
/// ``StandardStreams`` is static, so a command that writes to it directly can only be checked by reading the process's own file descriptors, which every test running beside it shares. A command holding one of these instead can be driven in-process and asked what it printed, on which stream and in what order.
struct CommandOutput: Sendable {
    /// One line of the answer, to stdout.
    let emit: @Sendable (String) -> Void

    /// Bytes to stdout exactly as given, newline and all.
    let emitRaw: @Sendable (Data) -> Void

    /// One line to stderr, the complaint channel.
    let emitError: @Sendable (String) -> Void

    /// The standard streams, through ``StandardStreams`` — the part marker kept only when the environment says the reader needs it (Claude Code's `CLAUDECODE`, or `SIFT_PART_MARKER=1`), stripped otherwise, terminal or not.
    static let standard = CommandOutput(
        keepsPartMarker: {
            let environment = ProcessInfo.processInfo.environment
            return environment["CLAUDECODE"] != nil || environment["SIFT_PART_MARKER"] == "1"
        }(),
        emit: { StandardStreams.emit($0) },
        emitRaw: { StandardStreams.emitRaw($0) },
        emitError: { StandardStreams.emitError($0) }
    )

    /// Wraps `emit` to strip ``SourcePassthrough/partMarker`` before the underlying sink sees it, unless `keepsPartMarker`.
    ///
    /// Whether stdout is a terminal is the wrong test: `TranscriptScan.creditAnswer` reads Claude Code's Bash tool results out of the transcript, and those arrive through a pipe like any other redirected output, so a plain `isatty` check strips the marker the one reader that needs it depends on. `keepsPartMarker` is decided from the environment at the `standard` construction site instead.
    ///
    /// `emitRaw` is never wrapped: the marker is only ever written by ``DigestRenderer``'s multi-part answers, which go out through `emit`, and decoding a chunk of a child process's raw output as UTF-8 to look for it would drop any chunk — or half of a multi-byte character split across two reads — that is not valid UTF-8.
    init(keepsPartMarker: Bool, emit: @escaping @Sendable (String) -> Void, emitRaw: @escaping @Sendable (Data) -> Void, emitError: @escaping @Sendable (String) -> Void) {
        if keepsPartMarker {
            self.emit = emit
        } else {
            self.emit = { emit(SourcePassthrough.strippingPartMarker(from: $0)) }
        }
        self.emitRaw = emitRaw
        self.emitError = emitError
    }
}
