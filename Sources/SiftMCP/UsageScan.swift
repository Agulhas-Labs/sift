//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The parsed, scoped view of `usage.jsonl` — the one reader behind both `usage` and `report`.
///
/// Two faces over one log — ``UsageReport`` and the HTML report — and a second parser would be a second answer to "how many calls" and a second measured-savings number: precisely the divergence one-generator-per-value exists to stop.
///
/// Read-tolerant by design: a malformed line is counted and skipped, never fatal, because the log is append-only best-effort and a partial line from a crashed writer must not wedge the review of every line around it.
public struct UsageScan: Sendable {
    /// The calls inside the window and root asked for.
    public let entries: [Entry]

    /// Every readable call in the log before scoping, so "nothing here" can say what it is nothing out of.
    public let logged: Int

    /// Lines that were not JSON this understands.
    public let malformed: Int

    /// The inclusive first day asked for, as the log files them (UTC).
    public let since: String?

    /// The directory a `--root` argument named, resolved against the roots both logs hold.
    public let resolvedRoot: String?

    /// True when calls from *below* the resolved root contributed, so a subtree total is never read as one repo's.
    ///
    /// Settled at load time rather than recomputed from `entries`, because deciding it means comparing paths canonically and that is a filesystem question — ``LogScope`` has already asked it once per distinct root by the time the entries are in hand.
    public let sweptSubtree: Bool

    /// Calls in the window and root that were made against scratch roots (temporary, cache or `.build` directories), left out of `entries` unless the load was asked to include them.
    public let scratchCalls: Int

    /// The one line both faces print when scratch calls were left out, or `nil` when none were.
    public var scratchNote: String? {
        guard scratchCalls > 0 else { return nil }
        return "\(scratchCalls) call\(scratchCalls == 1 ? "" : "s") against scratch roots (temporary, cache or .build directories) not counted"
    }

    /// When the CLI's first logged lookup was answered, over the whole log rather than the window — `nil` where the log holds none.
    ///
    /// Read before scoping because it dates a fact about the machine, not about the window: the day the CLI began logging is the same whichever root or days are asked about, and a window narrowed past it would otherwise date it to whatever CLI call happened to fall first inside.
    public let cliLoggedSince: String?

    /// Reads `fileURL` and narrows it, or reports why nothing can be read.
    ///
    /// `since` is an inclusive `YYYY-MM-DD` compared against the log's own day key, which is UTC because the timestamp is; `scope` is a directory already resolved by ``LogScope`` — resolved *there* rather than here so that one `--root` argument cannot mean one directory to this log and another to the run log beside it.
    ///
    /// A root scopes its whole subtree, not just calls filed under that exact path. Repos nest — a product folder over an app checkout, a checkout over its own linked worktrees — so scoping to the exact string answers "nothing happened in Depot" while every call sits one component below in `Depot/app`. Silence is the one wrong answer a usage review must never give.
    ///
    /// `includeScratch` is where scratch roots are told apart, once, for both faces: with it `false` a call whose root is scratch (``ScratchRoot``) is counted in `scratchCalls` and kept out of `entries`, so every figure drawn from them is real use only. The default keeps every call, which is what the readers that are not a usage review want.
    public static func load(fileURL: URL, since: String? = nil, scope: LogScope? = nil, includeScratch: Bool = true) -> Result<UsageScan, Problem> {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return .failure(.missingOrEmpty)
        }
        var parsed: [Entry] = []
        var malformed = 0
        for line in data.split(separator: 0x0A) {
            guard let entry = Entry(line: Data(line)) else {
                malformed += 1
                continue
            }
            parsed.append(entry)
        }
        guard !parsed.isEmpty else {
            return .failure(.unreadable(malformed: malformed))
        }

        let positions = scope?.positions(of: Set(parsed.map(\.root)))
        let windowed = parsed.filter { entry in
            (since.map { entry.day >= $0 } ?? true) && (positions.map { $0[entry.root] != nil } ?? true)
        }
        let scratchRoots = includeScratch ? [] : Set(windowed.map(\.root)).filter(ScratchRoot.contains)
        let scoped = windowed.filter { !scratchRoots.contains($0.root) }
        return .success(UsageScan(
            entries: scoped,
            logged: parsed.count,
            malformed: malformed,
            since: since,
            resolvedRoot: scope?.path,
            sweptSubtree: scoped.contains { positions?[$0.root] == .below },
            scratchCalls: windowed.count - scoped.count,
            cliLoggedSince: parsed.filter { $0.via == "cli" }.map(\.stamp).min()
        ))
    }

    /// What the measured calls in scope saved, or `nil` when none of them measured anything.
    ///
    /// Summed on both sides rather than averaged over per-call ratios: a mean would let a handful of tiny answers — the shapes a digest compresses worst — outweigh the large ones the tool exists for, and read as a worse result than the log actually holds.
    ///
    /// **Three populations, kept apart.** The calls that compressed and the calls the compression floor decided to serve source for are both measured, and averaging them into one ratio lets answers the tool *declined to compress* drag down the ones where it won — 73% where the compressing calls alone come to 77%, on the committed usage-log fixture. Beside them sit the calls that recorded no denominator at all, and they are not a saving of zero either: they are an absence, and an absence folded into a ratio is a number about nothing. So each is counted separately and stated separately, and the total says it is a floor.
    public var savings: Savings? {
        let measured = entries.compactMap { entry in entry.measured.map { (tool: entry.tool, day: entry.day, bytes: $0) } }
        let source = measured.reduce(0) { $0 + $1.bytes.source }
        guard !measured.isEmpty, source > 0 else { return nil }
        // Carried only when the window actually reaches back past the fields, which is what a call with no
        // measurement *before* the first measured day proves. An unmeasured call after that day is an
        // ordinary one — `where` and `search` stand in for a grep, not a run of source, and never measure —
        // so dating the onset on their account would explain a denominator by something that is not its cause.
        //
        // The call has to have *succeeded* for that proof to hold. A failed `digest` records no bytes
        // whatever version wrote it — a refusal replaces no source — and an answer that stands in for
        // nothing measures nothing, so a pre-onset failure would date the fields to a day that proves only
        // that something went wrong, which is the same wrong-cause error one line up.
        let firstMeasured = measured.map(\.day).min()
        let measuring = Set(measured.map(\.tool))
        let reachesPastTheFields = firstMeasured.map { first in
            entries.contains { $0.succeeded && measuring.contains($0.tool) && $0.measured == nil && $0.day < first }
        } ?? false
        // An answer that came back no smaller than the source it stood in for did not compress it — that is
        // what the words mean, and it is the only split this log supports over its own history. A flag
        // written from now on would say the same thing about the calls made after today and nothing at all
        // about every call already in the log, which is the wrong trade for a number whose subject is the past.
        let compressing = measured.filter { $0.bytes.served < $0.bytes.source }
        let passthrough = measured.filter { $0.bytes.served >= $0.bytes.source }
        return Savings(
            split: compressing.isEmpty || passthrough.isEmpty
                ? []
                : [
                    Savings.Row(label: "compressed", of: compressing.map(\.bytes)),
                    Savings.Row(label: "served source", of: passthrough.map(\.bytes)),
                ],
            total: Savings.Row(label: "measured", of: measured.map(\.bytes)),
            calls: entries.count,
            tools: measuring.sorted(),
            measuredSince: reachesPastTheFields ? firstMeasured : nil,
            unrecorded: unrecorded(by: measuring),
            unpriced: unpriced(besides: measuring),
            subagents: attributedToSubagents,
            // No `cli` line anywhere leaves the clause in: a log that never saw the CLI and one that predates
            // its logging read the same, and only the second is missing lookups — so the floor keeps saying so.
            //
            // Decided on the window's own start instant against the onset's own instant, not on which entries
            // happen to sit in scope: a window can start before the CLI ever logged and still hold no entry
            // from that gap, and the clause is about what the window could reach, not about what it happened
            // to catch. `since` is a day (`YYYY-MM-DD`), read as that day's midnight, so it compares correctly
            // against the onset's full timestamp without truncating either side to a day: a window starting at
            // a day's midnight reaches past an onset later that same day, though the two share a day.
            reachesPastCLILogging: cliLoggedSince.map { onset in (since ?? "") < onset } ?? true
        )
    }

    /// The measured calls a subagent made, or `nil` when none of them names one.
    ///
    /// Measured calls only, so it is a share *of the figure it sits under* rather than a second population with its own arithmetic — a subagent's `where` calls save real context and measure nothing, exactly as a session's do, and are counted in neither.
    private var attributedToSubagents: Savings.Attributed? {
        let mine = entries.compactMap { entry in entry.agent.flatMap { agent in entry.measured.map { (agent, $0) } } }
        guard !mine.isEmpty else { return nil }
        return Savings.Attributed(
            row: Savings.Row(label: "subagents", of: mine.map(\.1)),
            agents: Set(mine.map(\.0)).count
        )
    }

    /// The calls by a measuring tool that recorded no bytes — the shortfall that would otherwise just shrink the denominator.
    ///
    /// Where only part of the `digest` calls carry both fields, the rest are invisible unless counted: a ratio "measured over M of N calls" says how many measured but not how many *could have* and didn't. Naming it makes a capture rate a stated fact rather than something a reader has to derive by subtraction.
    private func unrecorded(by measuring: Set<String>) -> Savings.Unrecorded? {
        let shortfall = entries.filter { measuring.contains($0.tool) && $0.measured == nil }
        guard !shortfall.isEmpty else { return nil }
        return Savings.Unrecorded(
            tools: Self.named(shortfall),
            calls: shortfall.count,
            failed: shortfall.filter { !$0.succeeded }.count
        )
    }

    /// The calls no denominator exists for, and how much of what they served has been recorded.
    ///
    /// Derived from which tools measured anything rather than from a list of names, so a tool that starts measuring leaves this set by itself and one that never does is never quietly forgotten.
    private func unpriced(besides measuring: Set<String>) -> Savings.Unpriced? {
        let unpriced = entries.filter { !measuring.contains($0.tool) }
        guard !unpriced.isEmpty else { return nil }
        let recorded = unpriced.compactMap(\.answer)
        // The same age test the measured onset uses, for the same reason and against its own later start
        // day: `outBytes` reached these tools long after it reached `digest`, so a window spanning that day
        // holds calls that are unrecorded because they are old, not because they served nothing.
        let firstRecorded = unpriced.filter { $0.answer != nil }.map(\.day).min()
        let reachesPastTheField = firstRecorded.map { first in
            unpriced.contains { $0.succeeded && $0.answer == nil && $0.day < first }
        } ?? false
        return Savings.Unpriced(
            tools: Self.named(unpriced),
            calls: unpriced.count,
            failed: unpriced.filter { !$0.succeeded }.count,
            recorded: recorded.count,
            served: recorded.reduce(0) { $0 + $1.served },
            recordedSince: reachesPastTheField ? firstRecorded : nil
        )
    }

    /// Groups the scoped calls by `key`, most-used first (ties alphabetical, so output stays deterministic).
    public func grouped(by key: (Entry) -> String) -> [(String, [Entry])] {
        Dictionary(grouping: entries, by: key)
            .map { ($0.key, $0.value) }
            .sorted { ($1.1.count, $0.0) < ($0.1.count, $1.0) }
    }

    /// The failed calls in scope, grouped by the reason they recorded, most-frequent first.
    ///
    /// Each group carries the days it happened on. A report read a week after the fix that answers most of it renders undated findings as current issues, which is the misreading `audit` was dated to stop.
    public var failureGroups: [FailureGroup] {
        grouped(entries.filter { !$0.succeeded }, by: { $0.error ?? Self.reasonlessPlaceholder }).map { reason, group in
            FailureGroup(
                reason: reason,
                count: group.count,
                isRecorded: group.contains { $0.error != nil },
                days: Self.days(of: group)
            )
        }
    }

    /// The most-asked-for targets in scope, most-frequent first — what this codebase is repeatedly asked about.
    ///
    /// `naming` is applied before grouping so a redacted report groups the pseudonyms it prints rather than printing one pseudonym over several counts.
    ///
    /// A call that named several targets counts once under each of them, since each is a name the codebase was asked about.
    public func topTargets(naming: (String) -> String = { $0 }) -> [TargetCount] {
        let targeted = entries.flatMap { entry in
            entry.targets.map { (key: "\(entry.tool) \(naming($0))", entry: entry) }
        }
        return Dictionary(grouping: targeted, by: \.key)
            .sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
            .map { key, group in
                TargetCount(label: key, count: group.count, days: Self.days(of: group.map(\.entry)))
            }
    }

    /// The tools a set of calls was made with, most-used first (ties alphabetical, so the wording is deterministic).
    ///
    /// The same ordering as the `by tool` listing above it, rather than plain alphabetical: a sentence that names four tools is read as naming the big ones first, and putting a tool with nineteen calls in a month ahead of `where` misdescribes the set in the reader's head before the numbers arrive.
    ///
    /// Read off the entries, so a tool this binary no longer exposes still names itself here when an old log holds its calls.
    private static func named(_ entries: [Entry]) -> [String] {
        Dictionary(grouping: entries, by: \.tool)
            .sorted { ($1.value.count, $0.key) < ($0.value.count, $1.key) }
            .map(\.key)
    }

    /// The placeholder a failure that predates the `err` field is grouped under.
    private static var reasonlessPlaceholder: String {
        "(no reason recorded — entry predates the err field)"
    }

    /// The distinct days a set of calls fall on, oldest first.
    private static func days(of entries: [Entry]) -> [String] {
        Set(entries.map(\.day)).sorted()
    }

    private func grouped(_ subset: [Entry], by key: (Entry) -> String) -> [(String, [Entry])] {
        Dictionary(grouping: subset, by: key)
            .map { ($0.key, $0.value) }
            .sorted { ($1.1.count, $0.0) < ($0.1.count, $1.0) }
    }

    /// The nearest-rank percentile of an already-sorted list.
    public static func percentile(_ sorted: [Int], _ rank: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, (sorted.count * rank + 99) / 100 - 1))
        return sorted[index]
    }
}

public extension UsageScan {
    /// Why a log could not be read, or a `--root` argument could not be resolved.
    ///
    /// Carried as data rather than as a rendered sentence: the CLI summary prints prose, the HTML page does not, and the two must agree on the *fact* without agreeing on the wording.
    enum Problem: Error, Sendable, Equatable {
        case missingOrEmpty
        case unreadable(malformed: Int)
        case rootUnmatched(argument: String, roots: [String])
        case rootAmbiguous(argument: String, matches: [String])
    }

    /// What one answer cost against the source it replaced, where the call measured both sides.
    struct Measured: Sendable, Equatable {
        public let served: Int
        public let source: Int
    }

    /// One parsed log line.
    struct Entry: Sendable, Equatable {
        public let tool: String
        public let target: String?
        /// Every target the call named: the several a `digest` recorded as `targets`, else `target` alone, else none.
        public let targets: [String]
        public let root: String
        public let milliseconds: Int
        public let succeeded: Bool
        public let error: String?

        /// When the call was answered, exactly as the log wrote it.
        ///
        /// Kept alongside the day rather than folded into it because two readers need two different resolutions of the same field: a usage review is filed by day, and deciding whether a server is still being spoken to is a question about minutes (``ServerRoster``).
        public let stamp: String

        /// The day the log filed this call under — the timestamp's UTC date, which is why `--since` resolves in UTC too.
        public var day: String {
            String(stamp.prefix(10))
        }

        /// The conversation this call belonged to, where one named itself.
        ///
        /// `nil` for a call made by a machine running the CLI directly, which has no conversation to attribute it to — the same reading ``UsageLog/currentSession`` gives it on the way in.
        public let session: String?

        /// What this call served, and the source it stood in for where one was measured — `nil` for a failure, and for every line written before the field existed.
        public let answer: AnswerBytes?

        /// The subagent that made this call, where a hook was there to name it.
        ///
        /// `nil` says only "not attributed to a subagent", and covers four situations the log cannot tell apart: the session's own call, a machine with no `PreToolUse` hook, a slip that could not be claimed, and every line written before its face recorded callers at all — every CLI lookup logged before the CLI claimed slips among them. So it supports a floor — *at least* this many calls were a subagent's — and never a total.
        public let agent: String?

        /// The face that answered where it was not the server — `hook` for a lookup the advice hook answered in place, `cli` for one of the query subcommands — and `nil` for the server's own calls.
        public let via: String?

        /// Both sides of this call's cost, where both were counted.
        ///
        /// Derived rather than stored, because the two halves arrive independently now: ``AnswerBytes`` carries a served size for every answered call and a denominator only where the tool read one, and a saving is exactly the case where both are present. Everything downstream that speaks of a *measured* call means this.
        public var measured: Measured? {
            answer.flatMap { answer in answer.source.map { Measured(served: answer.served, source: $0) } }
        }

        /// One log line, or `nil` when it is not one this understands.
        init?(line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let tool = object["tool"] as? String,
                  let root = object["root"] as? String,
                  let timestamp = object["ts"] as? String
            else {
                return nil
            }
            self.tool = tool
            self.root = root
            target = object["target"] as? String
            targets = object["targets"] as? [String] ?? target.map { [$0] } ?? []
            milliseconds = object["ms"] as? Int ?? 0
            succeeded = object["ok"] as? Bool ?? true
            error = object["err"] as? String
            stamp = timestamp
            session = object["session"] as? String
            // The served size stands on its own; the denominator does not. `srcBytes` is read only through
            // `outBytes`, so a line that somehow carried a source with nothing served — which the writer
            // cannot produce — is a measurement of nothing rather than an infinite saving.
            answer = (object["outBytes"] as? Int).map { AnswerBytes(served: $0, source: object["srcBytes"] as? Int) }
            agent = object["agent"] as? String
            via = object["via"] as? String
        }
    }

    /// One failure reason and how often it came back, with the days it did.
    struct FailureGroup: Sendable, Equatable {
        public let reason: String
        public let count: Int

        /// False when this group is the placeholder for entries logged before failures recorded a reason.
        public let isRecorded: Bool

        /// The distinct days these failures fall on, oldest first.
        public let days: [String]
    }

    /// One `tool target` pair and how often it was asked for, with the days it was.
    struct TargetCount: Sendable, Equatable {
        public let label: String
        public let count: Int
        public let days: [String]
    }

    /// The measured saving over the calls in scope that weighed themselves, and everything a reader needs in order not to mistake it for a total.
    ///
    /// The count of measured calls against the total is not decoration. Only the answers that stand in for a run of source measure themselves at all, so a ratio drawn from a fraction of the log would otherwise read as a claim about all of it — and this value's whole worth is that it is a measurement, stated with what it was measured over.
    ///
    /// Four facts, deliberately not one number: what compressed, what was served as source instead, what a measuring tool recorded nothing for, and what has no denominator to record. Each face lays them out in its own idiom; the wording of every claim they make is generated here, once, so the page and the summary cannot come to disagree about the same log.
    struct Savings: Sendable, Equatable {
        /// The compressing calls and the passthrough calls, each with its own arithmetic — empty when every measured call fell on one side, where a second row would only restate the total.
        public let split: [Row]

        /// Every measured call in scope, both sides summed.
        public let total: Row

        /// Every call in scope, measured or not — the denominator that keeps a partial aggregate from reading as a whole one.
        public let calls: Int

        /// The tools that measured a denominator at all, sorted.
        public let tools: [String]

        /// The earliest day a call in this window measured itself, when the window reaches back past the fields — otherwise `nil`.
        ///
        /// "Measured over a few dozen of a thousand-odd calls" invites exactly one reading, and it is the wrong one: that the tool sampled, or that most answers declined to weigh themselves. What actually happened is that the fields were added on a day the window spans, and everything before it is a log older than the measurement. Naming that day turns a number that looks like a defect into one that reads as an age, and it costs a clause.
        public let measuredSince: String?

        /// The calls by a measuring tool that recorded no bytes, or `nil` when every one of them did.
        public let unrecorded: Unrecorded?

        /// The calls no saving can honestly be claimed for, or `nil` when every call in scope was made by a measuring tool.
        public let unpriced: Unpriced?

        /// How much of the measured saving is work a subagent did, and how many subagents did it — `nil` when none of the measured calls carries a caller.
        ///
        /// A *floor within a floor*, and the wording says so where it is printed. Only calls a hook was present for carry an agent at all, so this can only ever understate; that is the right direction for the one number the tool is judged on, and the wrong direction to leave unstated.
        public let subagents: Attributed?

        /// Whether a lookup the CLI served before it began logging could fall inside this window — false only where every call in scope was answered after the log's first `cli` line.
        public let reachesPastCLILogging: Bool

        public var served: Int {
            total.served
        }

        public var source: Int {
            total.source
        }

        public var measured: Int {
            total.calls
        }

        /// What the measured answers cost as a percentage of the source they replaced.
        public var percent: Int {
            total.percent
        }

        /// That percentage as it must be printed: an answer that cost something never renders as having cost nothing.
        ///
        /// A rounded 0 here reads as a free answer, which is a stronger claim than the tool has ever been able to make and the exact opposite of the honest-numbers discipline the rest of this type is built on. `<1%` says small and says nonzero, and the two together are the truth.
        public var percentText: String {
            total.percentText
        }

        /// The one sentence both faces state the measurement in.
        ///
        /// Named while one tool does all the measuring, generic as soon as more than one does: the sum spans every measured call, so attributing it to a single tool then would be a wrong label on a real number.
        public var sentence: String {
            let subject = tools.count == 1 ? "\(tools[0]) served" : "measured answers served"
            let pronoun = tools.count == 1 ? "it" : "they"
            let onset = measuredSince.map { " — fields recorded since \($0)" } ?? ""
            return "\(subject) \(percentText) of the source \(pronoun) replaced "
                + "(measured over \(measured) of \(calls) call\(calls == 1 ? "" : "s")\(onset))"
        }

        /// The saving as the reader prices it — `~2.2M tokens saved (est. vs whole-file reads)`, gross — or `nil` in the one case where "saved" would be a lie: a window whose measured answers cost more than the source, which is what a run of nothing but passthroughs looks like.
        ///
        /// Context, in tokens, rather than bytes: tokens are the unit an agent's context is counted in. An estimate, marked as one, at the conservative ratio ``TokenEstimate`` documents.
        public var savedText: String? {
            total.saved > 0 ? TokenEstimate.saved(bytes: total.saved) : nil
        }

        /// What the estimate was made from — `8.7 MB gross at 4 bytes a token`, the bytes saved before anything read whole afterwards — so the arithmetic behind the token figure is on the page beside it, or `nil` when there is no saving to explain.
        public var savedBasis: String? {
            total.saved > 0 ? TokenEstimate.basis(bytes: total.saved) : nil
        }

        /// The headline both faces lead with — the absolute first, then the ratio.
        ///
        /// The ratio alone cannot answer the question anyone actually asks of it: how much. A percentage is a shape; the tokens not spent are the thing, and the measured bytes they were estimated from stand in the same line so the estimate is never quoted without its basis. It falls back to the sentence alone when nothing was saved. Either way it closes on the baseline (``TokenEstimate/baseline``), the one place this face says the figure leans high.
        public var headline: String {
            guard let savedText, let savedBasis else { return "\(sentence); \(TokenEstimate.baseline)" }
            return "\(savedText), \(savedBasis): \(sentence); \(TokenEstimate.baseline)"
        }

        /// Why the figure above is a floor, or `nil` when nothing in scope went unmeasured and it is simply the total.
        ///
        /// Never omitted where it applies. A saving quoted without the calls it could not see is the same overclaim as a ratio quoted without its denominator, one level up — and this one flatters in the *other* direction, which is exactly why it is easy to leave unsaid.
        ///
        /// **Two reasons, and it used to name one.** Unweighed calls are the reason the line was written for, and for a long time the larger reason went unsaid: a face that did not log left its lookups out of this file altogether, so the figure was a floor over a population the reader could not even see the size of. The CLI's four query subcommands log now, which fixes it going forward and not backwards — a window reaching back before they did holds none of the lookups they served, and the line says so rather than letting "only the calls above were weighed" imply the rest of the file was complete. A window lying wholly after that onset has no such lookup to miss, and there the second reason is left unsaid (``reachesPastCLILogging``).
        public var floorNote: String? {
            guard unrecorded != nil || unpriced != nil, let figure = savedText else { return nil }
            let weighed = "only the \(total.calls) call\(total.calls == 1 ? "" : "s") above were weighed"
            // No baseline here: the headline or caption this note sits under states it, and once is the rule.
            guard reachesPastCLILogging else { return "\(figure) leaves out what was not weighed: \(weighed)." }
            return "\(figure) leaves out what was not weighed: \(weighed), "
                + "and a lookup served before its face began logging is not in the log to weigh at all."
        }
    }
}

public extension UsageScan.Savings {
    /// One population of measured calls and the arithmetic over it.
    ///
    /// The same shape for the two sides and their sum, so a reader checks one row against the others rather than against three different presentations of the same numbers.
    struct Row: Sendable, Equatable {
        /// What this population is, in the words the summary prints beside its count.
        public let label: String

        public let calls: Int
        public let source: Int
        public let served: Int

        /// Negative for the answers that served source, which cost more than the source itself — the framing they carry is real bytes, and rounding that up to zero would be the flattering direction.
        public var saved: Int {
            source - served
        }

        /// What this row served as a percentage of the source it stood in for.
        public var percent: Int {
            source > 0 ? Int((Double(served) / Double(source) * 100).rounded()) : 0
        }

        public var percentText: String {
            percent == 0 && served > 0 ? "<1%" : "\(percent)%"
        }

        /// This row's arithmetic in words: how far under the source it served, or — for the answers that served source — what it cost over the source itself.
        ///
        /// The two readings are different claims and must not share a phrasing. "Nothing saved" is what a passthrough row reads as with its sign folded into the total, and it is wrong in the direction that matters: serving a file under a freshness header and a line of arithmetic costs more than the file, and a row that says so is the reason the total above it can be believed.
        public var outcome: String {
            if saved > 0 {
                let share = Int((Double(saved) / Double(source) * 100).rounded())
                return "\(ByteSize.short(saved)) under the source (\(share == 0 ? "<1" : "\(share)")% smaller)"
            }
            return "\(ByteSize.short(-saved)) more than the source itself (+\(max(0, percent - 100))%)"
        }

        init(label: String, calls: Int, source: Int, served: Int) {
            self.label = label
            self.calls = calls
            self.source = source
            self.served = served
        }

        fileprivate init(label: String, of measured: [UsageScan.Measured]) {
            self.init(
                label: label,
                calls: measured.count,
                source: measured.reduce(0) { $0 + $1.source },
                served: measured.reduce(0) { $0 + $1.served }
            )
        }
    }

    /// One population of measured calls attributed to subagents, and how many of them there were.
    struct Attributed: Sendable, Equatable {
        public let row: Row
        /// Distinct subagents behind those calls.
        public let agents: Int

        /// The line the summary prints, stated as a floor and naming what it is a floor of.
        public var note: String {
            let saved = row.saved > 0 ? "\(ByteSize.short(row.saved)) of that estimate" : "\(ByteSize.short(row.served)) served"
            return "\(saved) is work \(agents) subagent\(agents == 1 ? "" : "s") did — a floor, since only a "
                + "call a hook was present for names its caller at all"
        }
    }

    /// The calls by a tool that *does* measure a denominator, which nevertheless recorded none.
    struct Unrecorded: Sendable, Equatable {
        public let tools: [String]
        public let calls: Int

        /// How many of them failed.
        ///
        /// A refusal replaces no source and so records nothing under any version of the writer, which makes it a different explanation from the rest and one worth separating: it is already counted in the failures section, and folding it in here would make the capture rate look worse than the measurement is.
        public let failed: Int

        /// The line the two faces print beside the count.
        ///
        /// The remainder is given as a category rather than enumerated, because the shapes that reach it are not a closed list a reader could check off — a repo overview, a module listing, a member body, a miss, an ambiguity, a paged or signatures-only digest, and any site whose source could not be re-read. What they share is the only thing worth stating: nothing was weighed, so nothing is claimed.
        public var note: String {
            let single = calls == 1
            let subject = "\(tools.spelled) call\(single ? "" : "s") recorded no bytes"
            let shapes = "no run of source: a module listing, a member body, a miss, "
                + "or source that could not be re-read"
            if failed == calls {
                return "\(subject) — \(single ? "it failed" : "every one of them failed")"
            }
            guard failed > 0 else {
                return "\(subject) — \(single ? "it stands" : "they stand") in for \(shapes)"
            }
            return "\(subject) — \(failed) failed; the rest stand in for \(shapes)"
        }
    }

    /// The calls whose saving is not measurable at all, and how much of what they served is on the record.
    struct Unpriced: Sendable, Equatable {
        public let tools: [String]
        public let calls: Int

        /// How many of them failed, split out for the reason ``Unrecorded/failed`` is: a refusal replaces no source, so it does not stand in for an unrunnable grep — it stands in for nothing.
        public let failed: Int

        /// How many of them recorded what they served, and the sum of it — a served size needs no counterfactual, so this grows towards `calls` as the log ages past the day the field reached these tools.
        public let recorded: Int
        public let served: Int

        /// The first day one of them recorded what it served, when the window reaches back past that day.
        public let recordedSince: String?

        /// The line the two faces print beside the count.
        ///
        /// The refusals are named because they are a different claim, not because the arithmetic needs them: every number here is right without them, and the sentence around them would not be. Describing the whole population as standing in for a grep nobody ran is true of each of these calls except the ones that failed, and ``Unrecorded`` two lines above makes exactly that split in exactly these words — so leaving it out here would read as an oversight rather than as a distinction not worth drawing.
        public var note: String {
            let single = calls == 1
            let subject = "\(tools.spelled) call\(single ? "" : "s") stand\(single ? "s" : "") in for a grep "
                + "nobody ran and nobody can size — no saving is claimed for \(single ? "it" : "them")"
            let refused = switch failed {
            case 0: ""
            case calls: "; \(single ? "it failed" : "every one of them failed") and stands in for nothing"
            default: "; \(failed) of them failed and stand in for nothing"
            }
            guard recorded > 0 else {
                return "\(subject)\(refused), and \(single ? "it has not" : "none has") recorded what it served"
            }
            let onset = recordedSince.map { ", recorded since \($0)" } ?? ""
            guard recorded < calls else {
                return "\(subject)\(refused); \(single ? "it" : "they") served \(ByteSize.short(served))\(onset)"
            }
            return "\(subject)\(refused); \(recorded) of them served \(ByteSize.short(served))\(onset)"
        }
    }
}

private extension [String] {
    /// The list as a sentence reads it — "where, search and strings" — so a note naming several tools stays prose rather than becoming a slash-separated field.
    var spelled: String {
        guard count > 1 else { return first ?? "" }
        return dropLast().joined(separator: ", ") + " and " + (last ?? "")
    }
}
