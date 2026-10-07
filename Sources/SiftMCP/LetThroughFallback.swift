//
// Copyright © Agulhas Labs
//

import Foundation

/// How a call is scored and remembered where an earlier call of its turn, taken as answered when it was scored, turns out to have been let through.
///
/// The transcript writes every call of a turn before any result, so the scan reads the hook's answer to an earlier call off the call itself: a lookup scored cold with a call to offer is taken as one the hook answered. The hook lets most of those through instead, and then judged the later call with the earlier one still unanswered. What the hook did is written down in the earlier call's result; this is the later call as the hook judged it then, held until that result says which of the two readings was right — where it arrives before the later call's own, since otherwise the reading the call was scored under stands.
struct LetThroughFallback: Sendable, Equatable, Codable {
    /// The lookup the call is scored as with none of those earlier calls answered.
    var lookup: SwiftLookup

    /// The key the call's answer or refusal is remembered by with none of them answered.
    var key: String

    /// The readings an answer to the call stands for with none of them answered.
    var readings: [ServedReading]

    /// The earlier calls of the turn the call was scored after as answered, by `tool_use_id`, each with the key the scan would remember that answer by.
    var assumedAnswered: [String: String]

    /// Whether a result that has arrived says the hook let one of the earlier calls through: its result is in, and it left no answer under its key.
    ///
    /// A call whose result has not arrived yet keeps the reading it was scored under, which is the hook's order of judging.
    func applies(in state: TranscriptScanState) -> Bool {
        assumedAnswered.contains { id, key in
            state.pendingReads[id] == nil && !state.hookDenied.contains(key)
        }
    }

    /// The earlier calls of `turn` still waiting on a result that the hook is taken to have answered by the time it judges a later call of the turn, by `tool_use_id`, each with the key that answer is remembered by — beside `hookDenied`, the keys the hook holds as answered then.
    ///
    /// The hook runs once per call, in the order a turn wrote them, and records its answer before the next call's hook runs; the transcript writes every call of the turn before any result. So an earlier call's answer is read off the call itself, as the hook's own decision on the same inputs: a lookup scored cold with a call to offer is one the hook advised on. That is a guess, since the hook lets most such calls through, so a later call scored on it carries a second reading with these calls unanswered (``LetThroughFallback``), and the earlier call's result settles which where it arrives before the later call's own. Nothing is recorded ahead of the result — the pending call is read where it already waits — so the result goes on to confirm the key into `hookDenied` exactly once, or, where the hook let the call through after all, to drop it. A call of an earlier turn whose result never arrived is no longer pending an answer the hook could still give, and counts for nothing; nor does one whose key a result has already confirmed.
    static func answeredAhead(of turn: String?, in state: TranscriptScanState) -> [String: String] {
        guard let turn else { return [:] }
        return state.pendingReads.compactMapValues { read -> String? in
            guard read.turn == turn, !read.key.isEmpty, !state.hookDenied.contains(read.key), case .cold(_, missed: .some) = read.lookup else { return nil }
            return read.key
        }
    }

    /// Swaps a call's reading for the one with the earlier calls of its turn unanswered where their results say the hook let one through, returning the rescore that swap makes to the count.
    static func settle(_ pending: inout PendingRead, in state: TranscriptScanState) -> [TranscriptEvent] {
        guard let fallback = pending.fallback, fallback.applies(in: state) else { return [] }
        let rescored: [TranscriptEvent] = pending.counted && fallback.lookup != pending.lookup
            ? [.lookupRetracted(pending.lookup), .lookup(fallback.lookup)]
            : []
        pending.lookup = fallback.lookup
        pending.key = fallback.key
        pending.readings = fallback.readings
        pending.fallback = nil
        return rescored
    }
}
