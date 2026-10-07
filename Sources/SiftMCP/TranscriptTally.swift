//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Counts a session's Swift lookups, split by whether they went through the index or around it.
///
/// This is the denominator the usage log structurally cannot supply — and it is the measured share Docs/Design.md §8 names as the check on adoption failure. The log records calls the tool served and is blind to the raw reads that happened instead, so a count of calls reads like adoption whether the share behind it is tiny or large. The transcript holds both, which is why the count is taken here rather than added to the log.
///
/// Counting is deliberately **unflattering at the margins**. A search that merely mentions Swift, naming no symbol the index could be asked about, counts as a raw lookup even though some of those are not really substitutes, so the share this reports leans low rather than high. An adoption metric that rounds in its own favour is worth nothing.
///
/// **The route a lookup took is not what the share asks about.** A `sift where` run from Bash is the index serving a lookup as surely as `mcp__sift__where` is, and it counts in `indexed` for that reason (``cliServed``). It was once excluded, as a bias pointing the same way as the one above — but an excluded route is only a floor while it is rare, and it is not rare: a context running under an output style that mandates the Bash tool reaches the index almost entirely this way, so the error term scaled with a harness setting rather than with anything about the tool. That is a blind spot, not a floor, and a share with one cannot say how much of its complement is a genuine miss.
///
/// Unflattering is not the same as unfair, though. Five categories are tracked and excluded from the share, each for its own reason: a `guided` ranged read is the loop working; a `revisited` read is of a file already in context; a `belowFloor` read got exactly what a digest would have handed back; a `textSearches` search is one the index could not have answered at all — the advisor declared the question unanswerable (a count, or a search over no one file whose pattern names nothing at all — ``TextSearch``), or no index this machine knows declares the name it hunts for; and a `withheldOnWorth` lookup is one the index *could* have answered, withheld because the answer costs more round trips than the command it replaces.
///
/// **The last two are counted apart rather than pooled**, though they leave the share the same way, because they say opposite things about the index's reach: one is a lookup the index never owed, the other one it owned and lost on a judgement of worth. A share that excuses both under one name improves by redefinition, the number keeping its name and its report line while its meaning changes underneath — so the audit reports them on two rows, and prints beside the second the share a reader would get without it.
///
/// `readWholeAfterDigest` is tracked but **not** excused. A whole-file read after a digest means the file was read anyway, so it belongs in the denominator like any other read that went around the index. It is named for what it counts and nothing more: it is not a verdict on the digest, since a file is as often read whole for what no digest records — a comment, a string literal — as for anything the digest left out.
///
/// A sixth exclusion is decided later than the other five, and is the only one that is not a property of the lookup itself: `unreachable` is what a context's cold lookups become when the context could not reach the index at all. See ``couldNotReachTheIndex`` and ``scored``.
public struct TranscriptTally: Sendable, Equatable, Codable {
    /// Calls served by the sift MCP tools.
    public var indexed: Int
    /// Ranged reads of a file an index call had already located — the second half of the intended loop.
    public var guided: Int
    /// Files read whole after their digest: the read the index exists to save, paid in full, whatever it was for.
    public var readWholeAfterDigest: Int
    /// Re-reads of a file already open in that context.
    public var revisited: Int
    /// First touches of files a digest would have served as source anyway — nothing avoided, nothing lost.
    public var belowFloor: Int
    /// Swift lookups that went around the index: first touches worth compressing, and Swift-flavoured searches.
    public var cold: Int
    /// Those same searches split by what was missing — a pattern naming nothing recorded, a name no index declares, a file no call can name, a pipeline that filters what the read printed.
    ///
    /// **Stored where the single total used to be, because the total on its own cannot be acted on.** Each cause argues for a different change — recording more than declarations, indexing another tree, neither — so a reader who wants to know whether the tool should be reading comments needs the one count that stands for it, not the sum of four things that happen to leave the share the same way. The split is carried from ``TranscriptScan``'s withholding decision, which already tells them apart in order to withhold.
    public var textSearchCauses: TextSearchCauses

    /// Searches for text the index does not record, which the tool itself declined to claim it could have served — and whole reads of a file no index call can name, which it declines to refuse for the same reason.
    ///
    /// The ``TextSearch/Withholding/notRecorded`` half alone. A lookup the index could have answered and was withheld on worth is ``withheldOnWorth``, never this.
    ///
    /// The sum of ``textSearchCauses`` rather than a counter beside it, so the row and its breakdown cannot drift apart.
    public var textSearches: Int {
        textSearchCauses.total
    }

    /// Those same lookups split by which rule made the judgement — a grep of one file printing context, an alternation confined to the files it names, a read a later pipeline stage filters, a refusal whose identical re-run the hook allowed.
    ///
    /// Stored where the single total used to be, for the same reason ``textSearchCauses`` replaced ``textSearches``: the total alone cannot be acted on, and the split is carried from ``TranscriptScan``'s withholding decision rather than re-derived at the counting end.
    public var withheldOnWorthCauses: WithholdOnWorthCauses

    /// Lookups the index records and could have answered, withheld because the answer would have cost more round trips than the command it replaces.
    ///
    /// The ``TextSearch/Withholding/notWorthTheRoundTrips`` half — out of the share exactly as `textSearches` is, and never added to it. What separates them is not how they leave the share but what leaving it claims: these are lookups the index lost, and the audit prints the share a reader would get if they were counted as the misses they are (``shareTextCountingWithheldOnWorth``).
    ///
    /// The sum of ``withheldOnWorthCauses`` rather than a counter beside it, so the row and its breakdown cannot drift apart.
    public var withheldOnWorth: Int {
        withheldOnWorthCauses.total
    }

    /// Of `cold`, the Swift reads on a compound line the hook let run whole for its other statements (``SwiftLookup/batched(file:)``): a miss the agent could have avoided by putting the index call on the line in the read's place.
    public var batched: Int

    /// Index calls that came back as errors, which are the only entries worth interrupting anyone about.
    public var failed: Int
    /// Index calls the harness answered itself because the tool was not there to deliver them to — the server absent from the context.
    ///
    /// Not a lookup and in no lookup sum, like `failed`, and kept apart from it because the two say opposite things about the context. A failed call reached the server, which proves the tool was there; an unavailable one never did, which is evidence it was not — so it counts towards ``couldNotReachTheIndex`` beside the refusals rather than against it.
    public var unavailable: Int
    /// Index calls the permission check stopped: the user declined them at the prompt, or the auto-mode classifier could not rule on them in time.
    ///
    /// Not a lookup and in no lookup sum, and neither a failure nor a miss: the call was never made, so it is no failure of the index, and the permission step answered it, so it is no lookup that went around the index either. Retracted from `indexed` like the other two, since it answered nothing. It does say one thing about the context, which is why it is counted at all: the harness asks the user about, and the classifier rules on, only a tool the context holds, so a call stopped there proves the tool was there, as a failed one does. See ``couldNotReachTheIndex``.
    public var declined: Int
    /// Lookups this context was refused by the advice hook, whatever it did next.
    ///
    /// Not a lookup and in no lookup sum: a refused lookup never happened, and is retracted from the bucket it was counted in on the same result line. This counts the *advice*, and it is here rather than in the scan state because it has to pool per transcript and survive the tally cache exactly as the counts do.
    public var refusals: Int
    /// Cold lookups from a context that could not reach the index at all.
    ///
    /// **Never folded — only ``scored`` writes this.** A lookup cannot be classified into it as it is read, because whether the context could reach the index is a fact about the whole transcript and is not known until the last line of it. See ``couldNotReachTheIndex``.
    public var unreachable: Int

    /// Invocations of this tool's own CLI in a Bash block, whatever the subcommand: `sift where`, `sift digest`, a build wrapped in `sift run`, `sift status`.
    ///
    /// Not itself a lookup and in no lookup sum, because most subcommands are not lookups. This is here for one job, and takes every subcommand for it: it is the evidence that the context *could* reach the index, which is what ``couldNotReachTheIndex`` asks about and had no way to see, and a wrapped build proves the binary was on this context's path as surely as a query does. The lookup-shaped subset counts in the share instead, through ``cliServed``.
    public var cliCalls: Int

    /// Lookups the CLI served — a Bash `sift digest`/`where`/`search`/`strings` — every one of them already in `indexed`, since the index served it.
    ///
    /// Counted apart only so a report can say how much of `indexed` came off the CLI rather than the server, exactly as ``answered`` says how much of it the advice hook served. One per Bash block that carries at least one such invocation, which is the granularity `cliCalls` has always had and the granularity every other tool call is counted at.
    ///
    /// **A wrapped `sift run` is not here**, and neither is any other subcommand that answers no lookup. Which is the whole difficulty: `cliCalls` counts the tool being reached by any route, and the share may only count the tool answering a question about Swift.
    ///
    /// A CLI lookup is retracted the way an MCP one is only when the *line* itself errors — the Bash block's own `is_error`, which the transcript records on the same result line an MCP call's failure would (``TranscriptEvent/cliLookupRetracted``). It is never filed as an index failure, since that error may belong to another command sharing the line rather than to `digest`/`where`/`search`/`strings` itself. What still cannot be seen is an error inside a *successful* line's own output: a `sift where` that exits clean but printed "no repository is indexed at that root" is text inside a Bash block's output, and reading an error out of that would guess. So that shape still counts as a lookup served, which is the one place this rounds upward — against a numerator where a failed MCP call, or an errored CLI line, rounds down.
    public var cliServed: Int

    /// Whether this context's transcript records its whole tool list with none of this server's tools in it (``TranscriptScanState/recordedToolListWithoutIndex``), as of the last line folded.
    ///
    /// Not a count, and not decided here: copied from the scan state after every line, so a tool list that gains sift later takes it back with nothing to unwind. It lives on the tally because the tally is what a verdict is read from and what the tally cache holds per transcript. It is a fact about one context, so a pool of contexts claims it only where every part does — and ``pooled(_:)`` scores each context before adding it, so nothing reads it off a pool.
    public var recordedToolListWithoutIndex: Bool

    /// Whether this context's transcript records its whole tool list at all (``TranscriptScanState/recordsWholeToolList``), whatever it says about sift, as of the last line folded.
    ///
    /// Copied from the scan state the same way as ``recordedToolListWithoutIndex``, and read beside it: a context can hold none of sift's tools either because the whole list is on record without them, or because no line ever recorded the list whole at all — a report that means to tell those two apart reads this, not just the absence of ``heldIndexTools``.
    public var recordsWholeToolList: Bool

    /// Lookups the advice hook answered in the refusal's place — every one of them already in `indexed`, since the index served it.
    ///
    /// Not a refusal and not a lookup the context routed around: the hook ran the call the refusal would have named and handed over its answer. Counted apart only so a report can say how much of `indexed` the hook served rather than the server.
    public var answered: Int

    /// Of `answered`, those that left part of an alternation uncovered — the caveat line, naming what a search would still have to sweep for.
    public var partialAnswers: Int

    /// Of `partialAnswers`, those followed by the identical re-run their caveat promised, within the same session.
    public var partialAnswersSwept: Int

    /// Refusals that were the only call in their assistant turn, and so cost a round trip each.
    public var soloRefusals: Int

    /// The context those round trips re-sent, split the way the harness bills it and priced the way Anthropic does.
    ///
    /// Measured rather than estimated — the harness records it — and summed only over `soloRefusals`: a refusal that shared its turn cost no round trip of its own, and one answered in place cost none.
    public var resentCost: RoundTripCost

    /// `resentCost.rawTokens` — every token the priced round trips re-sent, whatever kind.
    public var resentTokens: Int {
        resentCost.rawTokens
    }

    /// Solo refusals whose next tool call was the identical call, re-run — same tool, same input, so the refusal bought nothing.
    public var reRunFollowUp: RefusalFollowUpTally

    /// Solo refusals whose next tool call reached for the index instead — an `mcp__sift__*` tool, or `sift digest`/`where`/`search`/`strings` from Bash.
    public var indexFollowUp: RefusalFollowUpTally

    /// Solo refusals whose next tool call was neither a re-run nor the index.
    public var otherFollowUp: RefusalFollowUpTally

    /// Solo refusals with no further tool call in their context — the transcript ends on the round trip.
    public var endedFollowUp: RefusalFollowUpTally

    /// In-place answers to reads of a file, and those of them read whole anyway (``AnswerThenRead``).
    public var answerMisses = AnswerMissTally()

    public init(
        indexed: Int = 0,
        guided: Int = 0,
        readWholeAfterDigest: Int = 0,
        revisited: Int = 0,
        belowFloor: Int = 0,
        cold: Int = 0,
        textSearchCauses: TextSearchCauses = TextSearchCauses(),
        withheldOnWorthCauses: WithholdOnWorthCauses = WithholdOnWorthCauses(),
        batched: Int = 0,
        failed: Int = 0,
        unavailable: Int = 0,
        declined: Int = 0,
        refusals: Int = 0,
        unreachable: Int = 0,
        cliCalls: Int = 0,
        cliServed: Int = 0,
        recordedToolListWithoutIndex: Bool = false,
        recordsWholeToolList: Bool = false,
        answered: Int = 0,
        partialAnswers: Int = 0,
        partialAnswersSwept: Int = 0,
        soloRefusals: Int = 0,
        resentCost: RoundTripCost = RoundTripCost(),
        reRunFollowUp: RefusalFollowUpTally = RefusalFollowUpTally(),
        indexFollowUp: RefusalFollowUpTally = RefusalFollowUpTally(),
        otherFollowUp: RefusalFollowUpTally = RefusalFollowUpTally(),
        endedFollowUp: RefusalFollowUpTally = RefusalFollowUpTally()
    ) {
        self.answered = answered
        self.partialAnswers = partialAnswers
        self.partialAnswersSwept = partialAnswersSwept
        self.soloRefusals = soloRefusals
        self.resentCost = resentCost
        self.reRunFollowUp = reRunFollowUp
        self.indexFollowUp = indexFollowUp
        self.otherFollowUp = otherFollowUp
        self.endedFollowUp = endedFollowUp
        self.indexed = indexed
        self.guided = guided
        self.readWholeAfterDigest = readWholeAfterDigest
        self.revisited = revisited
        self.belowFloor = belowFloor
        self.cold = cold
        self.textSearchCauses = textSearchCauses
        self.withheldOnWorthCauses = withheldOnWorthCauses
        self.batched = batched
        self.failed = failed
        self.unavailable = unavailable
        self.declined = declined
        self.refusals = refusals
        self.unreachable = unreachable
        self.cliCalls = cliCalls
        self.cliServed = cliServed
        self.recordedToolListWithoutIndex = recordedToolListWithoutIndex
        self.recordsWholeToolList = recordsWholeToolList
    }

    /// Refusals in one context, with not one index call anywhere in it, before its cold lookups stop counting against the share — where the transcript does not record the context's tool list whole, so the list itself cannot settle it.
    ///
    /// **Twelve, because a context holding the index converts almost at once or never.** A refusal names the call that answers it, so a context that has that call makes it within a refusal or two, and rarely later than a third. Twelve is four times that worst honest delay, and a context that genuinely lacks the tools runs well past it, so it is caught with room to spare.
    ///
    /// It has to be a floor rather than a number tuned to fit, because a context that simply has not called yet must never be excused: that would be the metric rounding in its own favour, which is the one thing this type may not do. So the error is one-sided on purpose — a context that genuinely had no tools and took eleven refusals stays in the denominator, and the share stays the floor it has always claimed to be.
    public static let refusalsWithoutAnIndexCall = 12

    /// Whether this context could not reach the index at all: it never once reached it by any route, and either its transcript records its whole tool list with no sift in it, or it was told what to call a dozen times over and never once called it.
    ///
    /// **The tool list is the direct evidence, and the refusals the fallback where there is none.** The harness writes down what each context could call — the full list in a `prompt_snapshot`, the held-back list in a `deferred_tools_delta` — so where both halves are on record and neither names this server, the context held nothing the advice named, however few refusals it took; waiting for twelve would leave a subagent that took three refusals and read forty files scored as forty choices. Where the list is not on record whole — an older harness, a snapshot offering a tool search with no delta — silence is not absence, and only the floor applies (``refusalsWithoutAnIndexCall``). Moving cold lookups out *raises* the share, so the evidence has to be the harness's own word, never the lack of one.
    ///
    /// **A fact about a whole context, so it can only be read off a whole transcript** — which is why it is asked here, when a report is assembled, and never while lookups are being classified. The scan is incremental and append-only: a lookup filed under this at line 400 could not be taken back out when line 900 makes an index call. Asked late, the exclusion lifts by itself on the next render — a context that finds the tools halfway through counts fully from that moment, with no state to unwind — and that self-correction is the whole reason for deciding late.
    ///
    /// `failed` sits beside `indexed` in the test because an index call that errored is retracted from `indexed` on its way out (``TranscriptScan``). A context whose every call failed still *made* calls, and had the tools to make them. `declined` sits there too: the harness asks the user about a call, and its classifier rules on one, only when the context holds the tool, so a call the permission check stopped — turned down, or not ruled on in time — is as sure a sign of access as one that failed.
    ///
    /// **`cliCalls` sits there for the same reason.** A subagent pinned to `tools: Read, Grep, Glob, Bash` that runs `sift` from Bash reaches the index by the only route it has; a tally that could not see a Bash `sift` call would go on calling that context unreachable for the rest of its life and moving its later cold lookups out of the denominator. Removing cold lookups *raises* the share, which is the one direction this may never round. A lookup-shaped CLI call now clears `indexed` as well, so what `cliCalls` still carries alone is every other subcommand — a wrapped build, a `sift status` — each of which proves access without answering a lookup.
    ///
    /// **`unavailable` is the one error that counts the other way.** A call the harness answered itself — no such tool in this context — never reached the server, so it proves nothing about the tool being there; it is the harness saying the tool was not. It stands beside the refusals as evidence rather than beside `failed` as proof of access, and the floor is unchanged: it takes a dozen such signals, of either kind, with never a call that got through.
    ///
    /// Only `cold` can move. `guided` and `readWholeAfterDigest` are both reads of a file an index call located, so a context that made none has neither; `belowFloor`, `revisited`, `textSearches` and `withheldOnWorth` are already out of the share.
    public var couldNotReachTheIndex: Bool {
        guard indexed == 0, failed == 0, declined == 0, cliCalls == 0 else { return false }
        return recordedToolListWithoutIndex || refusals + unavailable >= Self.refusalsWithoutAnIndexCall
    }

    /// These counts as a report scores them: the cold lookups of a context that could not reach the index move out of the share and into `unreachable`.
    public var scored: TranscriptTally {
        scored(inContext: self)
    }

    /// One slice of a context's counts, scored on the verdict for the whole context it came from.
    ///
    /// A day's row is a slice of one transcript, and a day cannot be judged on its own counters: a context has the index or it has not, and a Tuesday on which it happened to make no call is not a Tuesday on which it had none to make.
    public func scored(inContext context: TranscriptTally) -> TranscriptTally {
        guard context.couldNotReachTheIndex else { return self }
        var scored = self
        scored.unreachable += scored.cold
        scored.cold = 0
        scored.batched = 0
        return scored
    }

    /// Several contexts' counts pooled, each scored on its own access before it is added.
    ///
    /// The one place the per-context rule can be lost, so it is the one place pooling happens at all. A subagent transcript is its own context — its own tool list, its own refusals — and scoring the pooled sum instead would ask whether *the session* reached the index, which marks a whole session down for advice some of its agents held no tools to act on.
    public static func pooled(_ tallies: some Sequence<TranscriptTally>) -> TranscriptTally {
        tallies.reduce(into: TranscriptTally()) { $0 += $1.scored }
    }

    /// Every lookup that was a genuine choice between the index and something else.
    ///
    /// `readWholeAfterDigest` is in here, unlike the other exclusions, because the file was read whole *anyway*: the session paid the full cost and the index did not save it. Leaving it out would let five digests followed by five whole-file reads report 100%, which breaks the one property the share exists for — that the number falls when a session reads around the index.
    ///
    /// Read this after ``scored``, never before. A context with no index tools has its lookups in `cold` until it is scored, and a raw `total` therefore still counts the lookups that had no choice — which is exactly the claim this denominator is not allowed to make.
    public var total: Int {
        indexed + cold + readWholeAfterDigest
    }

    /// The index's share of those lookups, or `nil` when the session has made none.
    public var share: Int? {
        total > 0 ? Int((Double(indexed) / Double(total) * 100).rounded()) : nil
    }

    /// The indexed lookups the agent chose the index for: those the advice hook did not answer in a refusal's place.
    public var voluntary: Int {
        indexed - answered
    }

    /// The lookups that had a choice and are not the hook's to answer: the indexed and the cold.
    ///
    /// Read after ``scored``, as ``total`` is.
    public var voluntaryTotal: Int {
        indexed + cold
    }

    /// The voluntary share with its arithmetic, or `nil` when no lookup had a choice.
    ///
    /// The percentage is floored to `<1%` for a nonzero numerator, as ``shareText`` is.
    public var voluntaryShareText: String? {
        guard voluntaryTotal > 0 else { return nil }
        let percent = Int((Double(voluntary) / Double(voluntaryTotal) * 100).rounded())
        let text = percent == 0 && voluntary > 0 ? "<1%" : "\(percent)%"
        return "\(text) = (\(indexed) indexed − \(answered) answered) / (\(indexed) indexed + \(cold) cold)"
    }

    /// That share as it must be printed: a session that used the index never renders as one that did not.
    ///
    /// Read by `sift report` alone, for the share it shows beside the counts. The same floor `RunScan.Summary` and `UsageScan.Savings` already state applies: one digest against two hundred and one lookups rounds to 0, and "sift 0% of 201 lookups" claims the tool went unused for the whole session, which is a different and stronger thing than "barely used". `<1%` says small and says nonzero.
    public var shareText: String? {
        guard let share else { return nil }
        return share == 0 && indexed > 0 ? "<1%" : "\(share)%"
    }

    /// The share `shareText` would read with every lookup withheld on worth counted as one the index lost — scored per context before it is pooled, the same way `cold` itself is.
    ///
    /// **Printed beside the count it explains, so the excuse is explicable rather than merely smaller.** A row saying how many lookups were withheld says nothing about what withholding them bought; a reader cannot tell a rounding error from the difference between a tool that is used and one that is not. The counterfactual is the honest form of the same fact, and it is the number a reviewer asks for the moment the row exists.
    ///
    /// They join `cold` rather than being struck from the numerator, because that is what they are on this reading: lookups that had a choice and went the other way. `indexed` is untouched.
    ///
    /// Takes the unpooled, unscored tallies rather than an already-pooled one — `pooled` has already moved each context's `cold` into `unreachable` by the time this would need to move its `withheldOnWorth` the same way, and adding into `cold` at that point can no longer tell a context that had no choice from one that did: a `withheldOnWorth` lookup from a context that could not reach the index at all re-enters the denominator as if it had been a reachable miss. Scoring here, before pooling, keeps that lookup out exactly as its `cold` siblings already are.
    public static func shareTextCountingWithheldOnWorth(_ tallies: some Sequence<TranscriptTally>) -> String? {
        shareText(tallies, countingAsMisses: \.withheldOnWorth)
    }

    /// The share `shareText` read before a search of one file whose pattern names nothing a declaration could be was scored as the tree form is (``TextSearchCauses/patternInOneFile``): those searches counted as the misses they were, per context before pooling, as ``shareTextCountingWithheldOnWorth(_:)`` counts its own.
    ///
    /// Printed beside the share so the accounting change is read off the report rather than taken on trust: neither number hides the other.
    public static func shareTextCountingOneFileTextSearches(_ tallies: some Sequence<TranscriptTally>) -> String? {
        shareText(tallies, countingAsMisses: \.textSearchCauses.patternInOneFile)
    }

    /// How many one-file text searches the share counted as misses before they were scored as text searches — each context's own, where it could reach the index, since a context that could not has its misses out of the share anyway.
    public static func oneFileTextSearchesOnTheOldDenominator(_ tallies: some Sequence<TranscriptTally>) -> Int {
        tallies.reduce(0) { $0 + ($1.couldNotReachTheIndex ? 0 : $1.textSearchCauses.patternInOneFile) }
    }

    /// The share with each reachable context's `misses` added to its `cold`, scored per context before it is pooled.
    private static func shareText(_ tallies: some Sequence<TranscriptTally>, countingAsMisses misses: KeyPath<TranscriptTally, Int>) -> String? {
        let counted = tallies.reduce(into: TranscriptTally()) { partial, tally in
            var scoredTally = tally.scored
            if !tally.couldNotReachTheIndex {
                scoredTally.cold += scoredTally[keyPath: misses]
            }
            partial += scoredTally
        }
        return counted.shareText
    }

    public static func += (lhs: inout TranscriptTally, rhs: TranscriptTally) {
        lhs.indexed += rhs.indexed
        lhs.guided += rhs.guided
        lhs.readWholeAfterDigest += rhs.readWholeAfterDigest
        lhs.revisited += rhs.revisited
        lhs.belowFloor += rhs.belowFloor
        lhs.cold += rhs.cold
        lhs.textSearchCauses += rhs.textSearchCauses
        lhs.withheldOnWorthCauses += rhs.withheldOnWorthCauses
        lhs.batched += rhs.batched
        lhs.failed += rhs.failed
        lhs.unavailable += rhs.unavailable
        lhs.declined += rhs.declined
        lhs.refusals += rhs.refusals
        lhs.unreachable += rhs.unreachable
        lhs.cliCalls += rhs.cliCalls
        lhs.cliServed += rhs.cliServed
        lhs.recordedToolListWithoutIndex = lhs.recordedToolListWithoutIndex && rhs.recordedToolListWithoutIndex
        lhs.recordsWholeToolList = lhs.recordsWholeToolList && rhs.recordsWholeToolList
        lhs.answered += rhs.answered
        lhs.partialAnswers += rhs.partialAnswers
        lhs.partialAnswersSwept += rhs.partialAnswersSwept
        lhs.soloRefusals += rhs.soloRefusals
        lhs.resentCost += rhs.resentCost
        lhs.reRunFollowUp += rhs.reRunFollowUp
        lhs.indexFollowUp += rhs.indexFollowUp
        lhs.otherFollowUp += rhs.otherFollowUp
        lhs.endedFollowUp += rhs.endedFollowUp
        lhs.answerMisses += rhs.answerMisses
    }

    public mutating func fold(_ event: TranscriptEvent) {
        switch event {
        case .indexFailure:
            failed += 1
        case .indexUnavailable:
            unavailable += 1
        case .indexDeclined:
            declined += 1
        case .lookupRefused:
            refusals += 1
        case .cliCall:
            cliCalls += 1
        case .cliLookup:
            cliServed += 1
        case .cliLookupRetracted:
            cliServed -= 1
        case .answeredInPlace:
            answered += 1
        case let .partialAnswer(uncovered):
            partialAnswers += uncovered > 0 ? 1 : 0
        case .partialAnswerSwept:
            partialAnswersSwept += 1
        case let .fileAnswer(shape, saving):
            answerMisses.answers[shape, default: 0] += 1
            answerMisses.claimed += saving
        case let .answerReadAnyway(shape, saving):
            answerMisses.misses[shape, default: 0] += 1
            answerMisses.withdrawn += saving
        case let .refusalRoundTrip(cost):
            soloRefusals += 1
            resentCost += cost
        case let .refusalFollowUp(followUp, cost):
            switch followUp {
            case .reRun:
                reRunFollowUp.count += 1
                reRunFollowUp.inputEquivalentTokens += cost.inputEquivalentTokens
            case .index:
                indexFollowUp.count += 1
                indexFollowUp.inputEquivalentTokens += cost.inputEquivalentTokens
            case .other:
                otherFollowUp.count += 1
                otherFollowUp.inputEquivalentTokens += cost.inputEquivalentTokens
            case .ended:
                endedFollowUp.count += 1
                endedFollowUp.inputEquivalentTokens += cost.inputEquivalentTokens
            }
        case .lookup(.indexed):
            indexed += 1
        case .lookup(.guided):
            guided += 1
        case .lookup(.readWholeAfterDigest):
            readWholeAfterDigest += 1
        case .lookup(.revisited):
            revisited += 1
        case .lookup(.belowFloor):
            belowFloor += 1
        case .lookup(.cold):
            cold += 1
        case let .lookup(.textSearch(cause)):
            textSearchCauses[cause] += 1
        case let .lookup(.withheldOnWorth(rule)):
            withheldOnWorthCauses[rule] += 1
        case .lookup(.batched):
            cold += 1
            batched += 1
        case let .lookupRetracted(lookup):
            switch lookup {
            case .indexed:
                indexed -= 1
            case .guided:
                guided -= 1
            case .readWholeAfterDigest:
                readWholeAfterDigest -= 1
            case .revisited:
                revisited -= 1
            case .belowFloor:
                belowFloor -= 1
            case .cold:
                cold -= 1
            case let .textSearch(cause):
                textSearchCauses[cause] -= 1
            case let .withheldOnWorth(rule):
                withheldOnWorthCauses[rule] -= 1
            case .batched:
                cold -= 1
                batched -= 1
            }
        }
    }
}
