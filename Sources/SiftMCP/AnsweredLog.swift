//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The calls the hook answered in place, by `tool_use_id`, one JSON line each — the proof that a result was sift's answer however it was delivered.
///
/// An answer reaches the model as the denial's text, which the harness shows as a hook error, and the transcript scan recognises it by that flag and the opening line. A transport that hands the same text over as an ordinary result leaves the transcript with nothing to tell it from a file's lines. This log is the record that does: the scan treats a call named here exactly as it treats an error-delivered answer, and never reads the result's text to decide.
///
/// Written by the `pre-tool-use` hook only where it prints the answer, just before it does — a built answer that was withheld, or one the ledger refused to record a denial for, is not an answer given and is never logged. Append-only beside the suppression log and, like it, never trimmed: an audit re-scans transcripts a week old. Best-effort like every log of this kind, through ``SiftCore/JSONLineLog``.
///
/// Beside the log, a marker per call — a file in `answers/` named by the call id, holding the answer's opening line — lets a caller that must not scan a growing log ask whether one call was answered with a single `stat`. Markers older than ``markerLifetime`` are removed whenever one is written, so nothing needs to run to keep the directory small.
public struct AnsweredLog: Sendable {
    /// How long a marker is kept: the answer it names was delivered in the turn that wrote it.
    public static let markerLifetime: TimeInterval = 24 * 60 * 60

    private let log: JSONLineLog
    private let markers: URL

    public init(fileURL: URL, markers: URL) {
        log = JSONLineLog(fileURL: fileURL, subject: "answered log")
        self.markers = markers
    }

    /// The shared per-user record, beside the suppression log it is read with.
    public static func standard() -> AnsweredLog {
        AnsweredLog(fileURL: standardFileURL, markers: standardMarkersDirectory)
    }

    /// Where the shared per-user record lives.
    public static var standardFileURL: URL {
        AdviceLedger.standardDirectory().appendingPathComponent("answered.jsonl")
    }

    /// Where the shared per-user markers live.
    public static var standardMarkersDirectory: URL {
        AdviceLedger.standardDirectory().appendingPathComponent("answers", isDirectory: true)
    }

    /// The log kept beside the suppression log at `suppressionLog`, so a caller that was handed one file is never handed a second.
    public static func fileURL(besideSuppressionLog suppressionLog: URL) -> URL {
        suppressionLog.deletingLastPathComponent().appendingPathComponent("answered.jsonl")
    }

    /// Records that the answer opening with `opening` was given for `call`, and leaves its marker.
    ///
    /// A call id that is not one file name — empty, or holding a separator — gets its log line and no marker, since a marker is a path built from it.
    public func note(call: String, opening: String, now: Date = Date()) {
        log.append(["call": call, "ts": ISO8601DateFormatter().string(from: now)])
        guard !call.isEmpty, !call.contains("/"), call != ".", call != ".." else { return }
        let files = FileManager.default
        try? files.createDirectory(at: markers, withIntermediateDirectories: true)
        pruneMarkers(before: now.addingTimeInterval(-Self.markerLifetime))
        try? Data(opening.utf8).write(to: markers.appendingPathComponent(call), options: .atomic)
    }

    /// The `tool_use_id`s the log at `fileURL` records as answered, or none where it cannot be read.
    public static func calls(in fileURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var calls: Set<String> = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let call = entry["call"] as? String
            else { continue }
            calls.insert(call)
        }
        return calls
    }

    private func pruneMarkers(before cutoff: Date) {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let kept = try? files.contentsOfDirectory(at: markers, includingPropertiesForKeys: keys) else { return }
        for marker in kept {
            if let modified = try? marker.resourceValues(forKeys: Set(keys)).contentModificationDate, modified < cutoff {
                try? files.removeItem(at: marker)
            }
        }
    }
}
