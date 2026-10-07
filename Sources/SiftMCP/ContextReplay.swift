//
// Copyright © Agulhas Labs
//

import Foundation

/// One context's scan and replay, by day as well as in total, so each day's share can be scored against the whole context's access.
struct ContextReplay {
    var tally = TranscriptTally()
    var byDay: [String: TranscriptTally] = [:]
    var replay = ReplayTally()
    var replayByDay: [String: ReplayTally] = [:]
    /// The cold lookups as the other hook scored them, where a replay puts every call to two.
    var against = ReplayTally()
    /// How many calls in the window both hooks judged, where a replay puts every call to two.
    var compared = 0
    /// The calls in the window the two hooks judged differently, by the other hook's rule and this one's.
    var changes: [String: [ReplayColdCall: Int]] = [:]
    /// The index calls behind each change of served call alone, as written, `theirs → ours`, by the change's shaped label: what an unredacted report shows beside a label whose two shapes can read alike.
    var servedCalls: [String: [String: Int]] = [:]

    /// Counts `delta` cold lookups under `outcome` on `day`, made by `call` where one is known; the calls are kept for the whole context, never per day.
    mutating func count(_ outcome: ReplayOutcome, day: String?, call: ReplayColdCall? = nil, by delta: Int = 1) {
        replay.count(outcome, call: call, by: delta)
        replayByDay[day ?? "undated", default: ReplayTally()].count(outcome, by: delta)
    }

    /// Counts `delta` cold lookups on `day` that the hook's log records letting run on worth, for this hook and the other alike, since the log is neither's verdict.
    mutating func countLogged(day: String?, by delta: Int = 1) {
        replay.loggedOnWorth += delta
        replayByDay[day ?? "undated", default: ReplayTally()].loggedOnWorth += delta
        against.loggedOnWorth += delta
    }

    /// Notes one call in the window both hooks judged, and the call itself under the change where `theirs` and `ours` differ in verdict, rule or the index call that answers it.
    ///
    /// A change of rule is named by both rules, else a change of verdict by both tokens, else a change of served call alone by both calls, each shaped by ``shaped(_:)`` so the label names nothing in the tree; the two calls as written are kept in ``servedCalls`` for a report that may show them.
    mutating func compare(_ theirs: ReplayVerdict?, with ours: ReplayVerdict?, payload: [String: Any]) {
        compared += 1
        guard theirs?.token != ours?.token || theirs?.rule != ours?.rule || theirs?.call != ours?.call else { return }
        let (old, new) = (theirs?.rule ?? "notHooked", ours?.rule ?? "notHooked")
        let change = if old != new {
            "\(old) → \(new)"
        } else if theirs?.token != ours?.token {
            "\(new) (\(theirs?.token ?? "none") → \(ours?.token ?? "none"))"
        } else {
            "\(new) [call \(Self.shaped(theirs?.call)) → \(Self.shaped(ours?.call))]"
        }
        if old == new, theirs?.token == ours?.token {
            servedCalls[change, default: [:]]["\(theirs?.call ?? "none") → \(ours?.call ?? "none")", default: 0] += 1
        }
        let call = ReplayColdCall(payload: payload, answerBytes: nil) ?? ReplayColdCall(text: "unnamed")
        changes[change, default: [:]][call, default: 0] += 1
    }

    /// The index call a verdict's answer ran, naming nothing in the tree, or `none` where it ran none: `sift` and the index tool as written, a line window as `:<range>`, and every other word as the kind of thing it is.
    static func shaped(_ call: String?) -> String {
        guard let call else { return "none" }
        let tools = TranscriptAudit.CallRedaction.subcommandsByTool["sift"]?.first ?? []
        return call.split(separator: " ").map { word in
            let word = String(word)
            guard word != "sift", !tools.contains(word) else { return word }
            guard let colon = word.lastIndex(of: ":"), Self.isWindow(word[word.index(after: colon)...]) else {
                return ShapeTokenReader.placeholder(for: word)
            }
            return ShapeTokenReader.placeholder(for: String(word[..<colon])) + ":<range>"
        }.joined(separator: " ")
    }

    /// Whether `suffix` is a line or a line window, `12` or `12-40`.
    private static func isWindow(_ suffix: Substring) -> Bool {
        let bounds = suffix.split(separator: "-", omittingEmptySubsequences: false)
        return (1 ... 2).contains(bounds.count) && bounds.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
