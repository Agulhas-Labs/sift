//
// Copyright © Agulhas Labs
//

import Foundation

/// Appends one JSON object per line to a file, best-effort — the mechanism under every JSONL ledger this tool keeps.
///
/// There are four of them and they mean different things: `usage.jsonl` records index lookups, whichever face served them, `run.jsonl` records wrapped toolchain runs, `server.jsonl` records servers starting and stopping, and `advice/suppressions.jsonl` records the denials the advice gate held back. What they must never differ in is *how* they behave, so the appending is written once — sorted keys so a line is stable to read and to diff, a newline terminator, the directory created on demand, and every failure swallowed after exactly one note.
///
/// Nothing here may raise or block. A ledger is a record of work, never a precondition for it: the MCP server's protocol stream and the wrapped command's output and exit code both have to be untouched by whether this file could be written.
public struct JSONLineLog: Sendable {
    public let fileURL: URL

    /// How this log names itself in the one note a failure gets, since "write failed" alone leaves a reader with no idea which file to look at.
    private let subject: String

    private let note: @Sendable (String) -> Void

    public init(fileURL: URL, subject: String, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.subject = subject
        self.note = note
    }

    /// Appends `entry` as one line, or notes why it could not be.
    public func append(_ entry: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            note("\(subject) entry failed to encode")
            return
        }
        data.append(0x0A)
        do {
            try write(data)
        } catch {
            note("\(subject) write failed (\(error))")
        }
    }

    /// Appends the bytes as one line, atomically against every other process appending to the same file.
    ///
    /// **A check-then-seek append loses lines, and the loss is silent.** Opening the file `O_WRONLY`, seeking to the end, and writing is three steps, and the offset the seek resolved goes stale the instant another process appends: concurrent appenders lose a large share of their lines that way, and leave some of the survivors malformed. Every one of these files is written by several processes at once by construction — one server per session, plus every hook and every wrapped run — so this is not a rare interleaving.
    ///
    /// The defence is both halves, because they answer different things. `O_APPEND` moves the seek into the write as one kernel operation, so no offset can go stale. The lock serialises the whole call against the *rewrite* in ``SiftMCP/ServerLifecycleLog``, which `O_APPEND` alone cannot help with: a file being trimmed under an appender is a hole in a file, not an interleaved line.
    ///
    /// What a lost line costs is worst in the server log. A missing *stop* entry makes `sift status` report a server that exited perfectly normally as one that "started and never recorded a stop" — a fabricated crash, from the one artefact built to stop people guessing.
    private func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `O_CLOEXEC` so a lock never outlives this call by riding a `git` child: the freshness header spawns
        // subprocesses from the same process that appends here, and an inherited descriptor holds the flock
        // for the child's whole life.
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Self.failure(errno) }
        defer { close(descriptor) }
        // An unavailable or contended lock still writes: `O_APPEND` alone keeps the line whole, which is the
        // larger half, and waiting here would stall the tool call this append is recording.
        FileLock.take(descriptor, .exclusive)
        defer { FileLock.release(descriptor) }
        try Self.writeAll(data, to: descriptor)
    }

    /// Writes every byte, since one `write` may satisfy only part of a buffer.
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                // Reset first: `errno` is only meaningful after a call that failed, and reading a stale one
                // left over from somewhere else could spin this loop forever on a bogus `EINTR`.
                errno = 0
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else {
                    let code = errno
                    guard code == EINTR else { throw failure(code) }
                    continue
                }
                offset += written
            }
        }
    }

    private static func failure(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
}
