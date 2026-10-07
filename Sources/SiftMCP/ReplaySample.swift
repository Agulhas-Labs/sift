//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// The sessions a bounded replay puts to the hook: a snapshot's lowest-ranked sessions, each with every subagent it had, until they hold `limit` contexts.
///
/// A replay's time follows the contexts it walks, and one orchestrator session can hold seventy, so `audit --replay` bounds its sample by contexts unless asked for every session. The sample ranks each session by a digest of its file name and keeps the lowest, so two runs over the same window pick the same sessions whatever order they were listed in. The session that reaches the bound is kept whole, never passed over for a smaller one, so a sample is never steered away from orchestrator sessions. The chosen sessions keep the snapshot's order.
public struct ReplaySample: Sendable {
    /// How many contexts to replay before stopping, the session that reaches it kept whole; `nil` replays every session.
    public let limit: Int?

    public init(limit: Int?) {
        self.limit = limit
    }

    /// Every session, for a replay with no bound.
    public static let everySession = ReplaySample(limit: nil)

    /// The sessions of `sessions` this sample replays, in the order `sessions` lists them.
    ///
    /// Only a session `holds` reports a lookup in is ranked, the window being the replay's, so a default sample does not spend its places on sessions of a non-Swift project, or whose calls all fall after `--until`, and read "unchanged" with almost nothing behind it. `contexts` counts a session's contexts, itself and its subagents, one each where it is not given. Sessions are asked in rank order and only as far as the limit needs.
    func chosen(from sessions: [URL], holdingLookups holds: (URL) -> Bool = { _ in true }, contexts: (URL) -> Int = { _ in 1 }) -> [URL] {
        guard let limit, sessions.reduce(0, { $0 + contexts($1) }) > limit else { return sessions }
        let ranked = sessions.map { (rank: Self.rank(of: $0.path), path: $0.path) }.sorted { ($0.rank, $0.path) < ($1.rank, $1.path) }
        var kept: Set<String> = []
        var replayed = 0
        for candidate in ranked where replayed < limit {
            let session = URL(fileURLWithPath: candidate.path)
            if holds(session) {
                kept.insert(candidate.path)
                replayed += contexts(session)
            }
        }
        return sessions.filter { kept.contains($0.path) }
    }

    /// Whether a transcript's lines hold a tool call made inside `since`..<`until` that looks up Swift source or calls this tool, read off the bytes without a JSON parse.
    ///
    /// An approximation that only ranks: a session it passes may still replay no lookup, and the replay itself decides what counts. A line with no timestamp is kept, as the scan keeps it.
    static func holdsLookup(_ data: Data, since: Date?, until: Date?) -> Bool {
        let marker = Data(#""type":"tool_use""#.utf8)
        let stamp = Data(#""timestamp":""#.utf8)
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(slice)
            guard line.range(of: marker) != nil,
                  line.range(of: Data(".swift".utf8)) != nil || line.range(of: Data(IndexToolName.prefix.utf8)) != nil
            else { continue }
            guard since != nil || until != nil else { return true }
            guard let start = line.range(of: stamp)?.upperBound,
                  let end = line[start...].firstIndex(of: UInt8(ascii: "\"")),
                  let text = String(data: line[start ..< end], encoding: .utf8),
                  let instant = TranscriptScan.instant(text)
            else { return true }
            if (since.map { instant >= $0 } ?? true), (until.map { instant < $0 } ?? true) {
                return true
            }
        }
        return false
    }

    /// `report` with a line saying the sample left sessions out, where it did, so its share is read as a sample's: under the section's heading where it has one, first where `--summary` dropped it.
    static func noted(_ report: [String], replayed: Int, of total: Int, contexts: Coverage = .unknown) -> [String] {
        guard replayed < total else { return report }
        var noted = report
        noted.insert(Self.note(replayed: replayed, of: total, contexts: contexts), at: report.first == "" ? min(2, report.count) : 0)
        return noted
    }

    /// `shapes`, the `--shapes` file's lines, with the sample note under its heading line where the sample left sessions out: its counts are the sample's as the report's are.
    static func notedShapes(_ shapes: [String], replayed: Int, of total: Int, contexts: Coverage = .unknown) -> [String] {
        guard replayed < total else { return shapes }
        var noted = shapes
        noted.insert(Self.note(replayed: replayed, of: total, contexts: contexts), at: min(1, shapes.count))
        return noted
    }

    private static func note(replayed: Int, of total: Int, contexts: Coverage) -> String {
        let counted = contexts.total > 0 ? ", \(contexts.replayed) of \(contexts.total) contexts" : ""
        return "  sampled \(replayed) of \(total) sessions (each with its subagents\(counted)); the replayed share and the audit's own beside it are this sample's — --sample 0 replays every session"
    }

    /// A session's place in the ranking: a digest of its file name, so it does not move with the directory it was listed from.
    private static func rank(of path: String) -> String {
        SHA256.hash(data: Data((path as NSString).lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ReplaySample {
    /// How many contexts a sample replayed out of the window's, for its note; zero of zero where they were not counted.
    struct Coverage: Sendable {
        let replayed: Int
        let total: Int

        static let unknown = Coverage(replayed: 0, total: 0)
    }
}
