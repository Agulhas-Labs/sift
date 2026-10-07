//
// Copyright © Agulhas Labs
//

import Foundation

/// Something worth counting on one transcript line.
public enum TranscriptEvent: Sendable, Equatable {
    case lookup(SwiftLookup)

    /// A lookup already counted, whose tool call then came back an error — take it back off the tally.
    ///
    /// A read that was *refused* never happened, so counting it describes a session that does not exist. The case this exists for is the advice hook denying a whole-file read: the deflection is the hook working, and scoring it as `readWholeAfterDigest` would count a read the hook prevented as one that happened, more of them the better the hook did. Retracting rather than deferring keeps the scan incremental — the status line folds each line once, as it arrives, and a call's result lands on a later line than the call.
    case lookupRetracted(SwiftLookup)

    /// A lookup the advice hook refused, naming the index call that answers it.
    ///
    /// Counted apart from the retraction that arrives on the same result line, because the two say different things. The retraction says the lookup did not happen; this says the advice was delivered — and the advice landing on a context that has no index tools at all is the one thing a transcript records about tool availability. Nothing else in a transcript does: a context that never called `digest` and a context that could not have looks identical member by member, and only the *count* of refusals it absorbed without ever once calling separates them. See ``TranscriptTally/couldNotReachTheIndex``.
    case lookupRefused

    /// An index call whose result came back an error, with what it was and what it said.
    case indexFailure(IndexFailure)

    /// An index call the harness answered itself, because the tool was not there to deliver it to.
    ///
    /// Not a failure of the index, which never saw the call, and not proof the context could reach it — the opposite: it is the harness saying, about this context, that the tool was unavailable. See ``TranscriptTally/unavailable``.
    case indexUnavailable

    /// An index call the permission check stopped — the user declined it at the prompt, or the auto-mode classifier could not rule on it in time — so it was never made.
    ///
    /// Not a failure of the index, which never saw the call, and not a lookup that went around it: the permission step answered it, which is a fact about the session rather than a measure of the tool. See ``TranscriptTally/declined``.
    case indexDeclined

    /// A lookup the advice hook answered in the refusal's place, running the index call itself (``InPlaceAnswer``).
    ///
    /// Arrives beside the `.lookup(.indexed)` that counts it, because it is the index serving the lookup — never a refusal the context routed around, and never cold. Counted on its own as well so a report can say how many of the index's answers the hook gave rather than the server.
    case answeredInPlace

    /// An in-place answer to a read of one file, with the saving in bytes its closing line claimed for that file.
    ///
    /// Counted beside ``answeredInPlace`` for answers to reads, outlines included, so the audit can set the ones read whole anyway against every one given.
    case fileAnswer(shape: AnswerShape, saving: Int)

    /// A ``fileAnswer`` whose file the same context then read whole within ``AnswerThenRead/window`` calls, its saving withdrawn.
    case answerReadAnyway(shape: AnswerShape, saving: Int)

    /// An in-place answer to an alternation that left part of it uncovered, naming how many branches the caveat line names.
    ///
    /// Arrives beside ``answeredInPlace`` on the same result line, never apart from it, so a report can say how often the shape fires without pooling it into every other in-place answer. Carries the count and not the branches themselves: what a report wants is the rate, and the branches are already in the transcript's own text for whoever reads it directly.
    case partialAnswer(uncovered: Int)

    /// The identical re-run a partial answer's caveat promised, arrived — the sweep for what it left uncovered.
    ///
    /// Raised once per partial answer, at the lookup its key matches (``TranscriptScanState/partialAnswered``), and never again for a further re-run of the same search: a second identical run is still the sanctioned escape hatch, but it is not a second sweep to count.
    case partialAnswerSwept

    /// A refusal that was the only call in its assistant turn, priced by the context the next turn re-sent: that turn's input tokens, cache reads and cache writes, from its `message.usage`.
    ///
    /// A refusal's own text is a few hundred bytes; what it costs is the round trip, since the context has to make another turn to act on it and every turn re-sends everything it holds. A refusal that shared its turn with other calls cost no round trip of its own — the next turn was coming for them anyway — and one answered in place cost none, so neither is priced.
    case refusalRoundTrip(cost: RoundTripCost)

    /// What followed a lone refusal's round trip — the next tool call the transcript wrote after it, classified and priced by the same round trip.
    ///
    /// Arrives on a later line than ``refusalRoundTrip(cost:)``, sometimes much later: the next call can open on a turn's own first block, or wait out a turn or two of prose first. Never arrives at all for a refusal the transcript ends on, whose classification is decided at the end of the scan instead (``RefusalFollowUp/ended``).
    case refusalFollowUp(RefusalFollowUp, cost: RoundTripCost)

    /// This tool's own CLI, invoked from a Bash block: `sift where`, `sift digest`, a build wrapped in `sift run`.
    ///
    /// Counted for one reason: it is proof the context *could* reach the index, which is the question ``TranscriptTally/couldNotReachTheIndex`` asks, and every subcommand answers it — a wrapped build proves the binary was there as surely as a query does. The advice hook reads a `sift` invocation as the advice being taken (`PreToolUseCommand.takesTheAdvice`), and the two are documented as one test asked of a live conversation and of a finished transcript; without this case they would not be.
    ///
    /// Not itself a lookup and in no lookup sum. The lookup-shaped half of these arrives as ``cliLookup`` beside a `.lookup(.indexed)` of its own.
    case cliCall

    /// A lookup the CLI served: a Bash `sift digest`/`where`/`search`/`strings`, which is the index answering a Swift lookup by the only route a context without the MCP tools has.
    ///
    /// Arrives beside the `.lookup(.indexed)` that counts it, exactly as ``answeredInPlace`` does, and counted on its own as well so a report can say how much of `indexed` came off the CLI rather than the server. A `sift run -- swift build` is not this: a wrapped build is not a lookup, so it raises ``cliCall`` alone.
    case cliLookup

    /// A ``cliLookup`` already counted, whose Bash line then came back an error — take it back off the tally, beside the ``lookupRetracted(_:)`` of the `.lookup(.indexed)` it arrived with.
    ///
    /// The error is the whole line's, which may belong to another command sharing it rather than the digest itself, so it is never filed as an index failure — only the count is taken back, exactly as an MCP call's is.
    case cliLookupRetracted
}
