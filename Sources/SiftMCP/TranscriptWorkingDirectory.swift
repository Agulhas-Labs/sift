//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The directory a session transcript was recorded in, which is what `audit --root` scopes by, and the answer naming where a window's sessions ran when none ran in the root.
struct TranscriptWorkingDirectory {
    /// The answer where the window holds sessions and none ran in `root` or below it: where they did run, most first, so the root that was meant can be named.
    static func noneIn(_ root: String, windowed: [URL], scope: String, path: String, redactor: Redactor?) -> String {
        let spelled = { (directory: String) in redactor?.root(directory) ?? directory }
        var counts: [String: Int] = [:]
        for session in windowed {
            counts[of(transcriptAt: session).map(CanonicalPath.of) ?? "", default: 0] += 1
        }
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let count = windowed.count
        var lines = ["no session\(scope) ran in \(spelled(root)) or below it — the \(count) session transcript\(count == 1 ? "" : "s") under \(path) ran in:"]
        for (directory, sessions) in ranked.prefix(5) {
            lines.append("  \(TranscriptAudit.pad(sessions))  \(directory.isEmpty ? "(no recorded directory)" : spelled(directory))")
        }
        if ranked.count > 5 {
            lines.append("  … and \(ranked.count - 5) more director\(ranked.count - 5 == 1 ? "y" : "ies")")
        }
        if redactor != nil {
            lines.append("(directories pseudonymised; --unredact names them)")
        }
        return lines.joined(separator: "\n")
    }

    /// The working directory a transcript was recorded in, read from the first of its opening lines that names one — a queued housekeeping line can open a session before its first real message does, and only a message line carries `cwd`.
    ///
    /// Bounded by line count, not by bytes: a queued line can itself run past a hundred kilobytes, and a fixed byte cap that cut one short would parse as nothing and drop the transcript from a scoped share. Read a chunk at a time instead, so a single long line is never truncated, and stop once the first `cwdProbeLineLimit` lines have been seen — comfortably past the handful of queued lines Claude Code can write before a session's first real message.
    static func of(transcriptAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var linesSeen = 0
        while linesSeen < cwdProbeLineLimit {
            guard let chunk = try? handle.read(upToCount: cwdProbeChunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while linesSeen < cwdProbeLineLimit, let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if let recordedCwd = cwd(inLine: line) {
                    return recordedCwd
                }
                buffer.removeSubrange(...newline)
                linesSeen += 1
            }
        }
        return linesSeen < cwdProbeLineLimit ? cwd(inLine: buffer) : nil
    }

    /// `cwd` from one JSONL line, or nil when the line has none or does not parse.
    private static func cwd(inLine line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let recordedCwd = object["cwd"] as? String
        else { return nil }
        return recordedCwd
    }

    /// How many of a transcript's opening lines are worth reading for a `cwd` — comfortably past the handful of queued lines Claude Code can write before a session's first real message.
    private static let cwdProbeLineLimit = 20
    /// The I/O chunk size the line-by-line probe reads in; not a cap on any one line's length.
    private static let cwdProbeChunkSize = 65536
}
