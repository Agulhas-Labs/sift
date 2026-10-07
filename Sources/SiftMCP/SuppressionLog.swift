//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The denials the gate held back, one JSON line each — so its fire rate is a number rather than a guess.
///
/// A gate that suppresses 90% of nudges and one that suppresses 2% look identical from the outside, and an invisible suppression rate is the same shape of problem as the adoption number this tool exists to make honest. Append-only beside the advice ledger, best-effort like the usage log: a failure to record must never decide whether a tool call happens, so every failure is swallowed.
///
/// The appending belongs to ``SiftCore/JSONLineLog``. Opening, seeking and writing here on its own is the pattern that appender documents losing lines under concurrent writers — and this log's writer is the `pre-tool-use` hook, one process per tool call, so concurrent appends are its ordinary traffic. A lost line is a withheld denial the rate never counts: the one number this log exists for, under-reported in silence.
public struct SuppressionLog: Sendable {
    private let log: JSONLineLog
    /// Told the rule of every entry as it is noted, so a replay that writes the log nowhere still learns which gate withheld a call.
    private let noted: (@Sendable (_ rule: String) -> Void)?

    public init(fileURL: URL, noted: (@Sendable (_ rule: String) -> Void)? = nil) {
        log = JSONLineLog(fileURL: fileURL, subject: "suppression log")
        self.noted = noted
    }

    /// The shared per-user record, beside the advice ledger it explains.
    public static func standard() -> SuppressionLog {
        SuppressionLog(fileURL: standardFileURL)
    }

    /// Where the shared per-user record lives.
    public static var standardFileURL: URL {
        AdviceLedger.standardDirectory().appendingPathComponent("suppressions.jsonl")
    }

    /// Records that a built suggestion was withheld for a lookup under `directory`, and which gate withheld it.
    ///
    /// `rule` because there is more than one gate, and a rate that cannot say *which* gate fired is the same shape of blindness as no rate at all — one over-firing rule inside a healthy total is invisible. `symbol` is optional for the same reason the gates differ: a search the index could not have served often names no symbol at all, which is precisely why it was withheld. `call` is the `tool_use_id` of the call judged, where the harness gave one, so the audit can find this verdict again for that call.
    public func note(symbol: String?, directory: String?, rule: String, call: String? = nil) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "rule": rule,
        ]
        if let symbol {
            entry["symbol"] = symbol
        }
        if let directory {
            entry["dir"] = directory
        }
        if let call {
            entry["call"] = call
        }
        log.append(entry)
        noted?(rule)
    }

    /// The rule the log at `fileURL` records for each of `calls`, as written, for the calls it names.
    ///
    /// Where a call has more than one entry the last wins. A line naming none of `calls` is skipped before it is parsed, because the log is never trimmed and a caller asks for a few ids.
    public static func rules(ofCalls calls: Set<String>, in fileURL: URL) -> [String: String] {
        guard !calls.isEmpty, let data = try? Data(contentsOf: fileURL) else { return [:] }
        let needles = calls.map { Data($0.utf8) }
        var rules: [String: String] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) where needles.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let call = entry["call"] as? String, calls.contains(call),
                  let rule = entry["rule"] as? String
            else { continue }
            rules[call] = rule
        }
        return rules
    }

    /// The `tool_use_id`s of the calls the log at `fileURL` records letting run with an in-place answer withheld — on worth, or for a line run whole for its other statements — each with the withholding it logged, or none where it cannot be read.
    ///
    /// Only an entry naming its call counts: one written before calls were named cannot be tied to a transcript's call, and a guess by time and directory could pin one call's verdict on another. Only the first `prefix` bytes are read where it is given, so two scans of one snapshot read the log as it stood when the snapshot was taken.
    public static func callsLetThrough(in fileURL: URL, prefix: Int? = nil) -> [String: InPlaceAnswerer.Withholding] {
        guard let whole = try? Data(contentsOf: fileURL) else { return [:] }
        let data = prefix.map { whole.prefix($0) } ?? whole
        let markers = [InPlaceAnswerer.Withholding.notSmaller, .otherStatementsRun, .linesNotShown, .notWorthTheTurn].map { Data("\"\($0.rawValue)\"".utf8) }
        var calls: [String: InPlaceAnswerer.Withholding] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["rule"] as? String == "answerWithheld",
                  let why = (entry["symbol"] as? String).flatMap(InPlaceAnswerer.Withholding.init(rawValue:)),
                  why == .otherStatementsRun || TextSearch.Rule(loggedAs: why) != nil,
                  let call = entry["call"] as? String
            else { continue }
            calls[call] = why
        }
        return calls
    }
}
