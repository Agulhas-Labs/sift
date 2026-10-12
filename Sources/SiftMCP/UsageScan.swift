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
        ScratchRoot.note(count: scratchCalls, noun: "call")
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
        var readAnyway = Set<ReadAnyway>()
        var malformed = 0
        for line in data.split(separator: 0x0A) {
            guard let entry = Entry(line: Data(line)) else {
                if let taken = ReadAnyway(line: Data(line)) {
                    readAnyway.insert(taken)
                } else {
                    malformed += 1
                }
                continue
            }
            parsed.append(entry)
        }
        guard !parsed.isEmpty else {
            return .failure(.unreadable(malformed: malformed))
        }
        // A hook answer the context then read anyway saved nothing: the line the hook wrote when it let the read
        // through names the answer, and the answer is marked, so every figure drawn from it leaves it unpriced.
        for index in parsed.indices where parsed[index].via == "hook" {
            guard let call = parsed[index].call, let target = parsed[index].target else { continue }
            parsed[index].readAnyway = readAnyway.contains(ReadAnyway(call: call, target: target, session: parsed[index].session))
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

    /// What the priced calls in scope saved, or `nil` when none was priced.
    ///
    /// **Priced only where the counterfactual was observed** (Docs/Design.md §4): a read the advice hook intercepted and answered in place, whose command named the file or the window it would have printed, so the saving is those bytes less the answer served. A call made by choice — a `digest`, `where`, `search` or `strings` by the server or the CLI — and a grep the hook answered stand in for something nobody ran and nobody can size, so they are counted and sized, never priced: a figure priced on a guess is worse than none.
    ///
    /// Summed on both sides rather than averaged over per-call ratios: a mean would let a handful of tiny answers outweigh the large ones.
    public var savings: Savings? {
        let priced = entries.compactMap(\.credited)
        guard !priced.isEmpty else { return nil }
        let compressing = priced.filter { $0.served < $0.source }
        let passthrough = priced.filter { $0.served >= $0.source }
        return Savings(
            split: compressing.isEmpty || passthrough.isEmpty
                ? []
                : [
                    Savings.Row(label: "compressed", of: compressing),
                    Savings.Row(label: "served source", of: passthrough),
                ],
            total: Savings.Row(label: "priced", of: priced),
            calls: entries.count,
            unpriced: unpriced,
            subagents: attributedToSubagents
        )
    }

    /// The Markdown outlines that measured themselves, kept out of the headline and reported whether or not any code call measured too, or `nil` when there were none.
    public var markdown: Savings.Markdown? {
        let measured = entries.compactMap(\.markdownShare)
        guard !measured.isEmpty else { return nil }
        return Savings.Markdown(row: Savings.Row(label: "markdown", of: measured))
    }

    /// The measured calls a subagent made, or `nil` when none of them names one.
    ///
    /// Measured calls only, so it is a share *of the figure it sits under* rather than a second population with its own arithmetic — a subagent's `where` calls save real context and measure nothing, exactly as a session's do, and are counted in neither.
    private var attributedToSubagents: Savings.Attributed? {
        let mine = entries.compactMap { entry in entry.agent.flatMap { agent in entry.credited.map { (agent, $0) } } }
        guard !mine.isEmpty else { return nil }
        return Savings.Attributed(
            row: Savings.Row(label: "subagents", of: mine.map(\.1)),
            agents: Set(mine.map(\.0)).count
        )
    }

    /// Every call in scope that is not priced, Markdown outlines apart (they have a line of their own), or `nil` when there is none.
    private var unpriced: Savings.Unpriced? {
        let unpriced = entries.filter { $0.credited == nil && !$0.isMarkdownOnly }
        guard !unpriced.isEmpty else { return nil }
        let recorded = unpriced.compactMap(\.answer)
        return Savings.Unpriced(
            tools: Self.named(unpriced),
            calls: unpriced.count,
            failed: unpriced.filter { !$0.succeeded }.count,
            recorded: recorded.count,
            served: recorded.reduce(0) { $0 + $1.served },
            unlabelled: unpriced.count(where: \.predatesItsPricing),
            readAnyway: unpriced.count(where: \.readAnyway)
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

    /// A line the hook wrote on letting a read through that an answer had stood in for: the answer's command id and target, in its session.
    struct ReadAnyway: Hashable {
        let call: String
        let target: String
        let session: String?

        init(call: String, target: String, session: String?) {
            self.call = call
            self.target = target
            self.session = session
        }

        /// One read-anyway line, or `nil` when the line is not one.
        init?(line: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let call = object["readAnyway"] as? String,
                  let target = object["target"] as? String
            else {
                return nil
            }
            self.init(call: call, target: target, session: object["session"] as? String)
        }
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

        /// What a call the hook answered in place stood in for — `file`, `window` or `other` (``InPlaceAnswerer/Interception``) — and `nil` for every other call and every hook line written before the field.
        public let intercepted: String?

        /// Both sides of this call's cost, where both were counted.
        ///
        /// Derived rather than stored, because the two halves arrive independently now: ``AnswerBytes`` carries a served size for every answered call and a denominator only where the tool read one, and a saving is exactly the case where both are present. Everything downstream that speaks of a *measured* call means this.
        public var measured: Measured? {
            answer.flatMap { answer in answer.source.map { Measured(served: answer.served, source: $0) } }
        }

        /// The names a call with several targets recorded one by one (`parts`), empty for every other call.
        public let parts: [Part]

        /// The harness's id for the command a hook answer stood in for, which a read-anyway line names; `nil` on every other line.
        public let call: String?

        /// For a whole file the hook intercepted a read of, the bytes of the lines one whole-file `Read` returns, as the hook measured them.
        public let readBytes: Int?

        /// Whether the context read anyway what this hook answer stood in for — re-ran the command, or read the file whole — so it saved nothing.
        public internal(set) var readAnyway = false

        /// What this call saved, where its counterfactual was observed.
        ///
        /// A whole file the hook intercepted a read of, against the bytes one whole-file `Read` of it returns (``readBytes``), or a window, its own bytes — each less the answer served. `nil` for every other call: a hook answer the context then read anyway, and a hook line written before the field its pricing needs (``predatesItsPricing``), among them.
        public var credited: Measured? {
            guard via == "hook", !readAnyway, let code = split.code, let measured else { return nil }
            return switch intercepted {
            case "file": readBytes.map { Measured(served: code.served, source: $0) }
            case "window": measured
            default: nil
            }
        }

        /// Whether this is a measured hook answer logged before the field that prices it: before ``intercepted``, or a whole file before ``readBytes``.
        var predatesItsPricing: Bool {
            via == "hook" && !readAnyway && measured != nil && (intercepted == nil || intercepted == "file" && readBytes == nil)
        }

        /// Whether the call named nothing but Markdown, which the outlines' own line reports.
        var isMarkdownOnly: Bool {
            markdownShare != nil && split.code == nil
        }

        /// The part of this call a Markdown document accounts for, reported on a line of its own and never in the headline saving, or `nil` where the call named none.
        ///
        /// Nobody reads a long design document whole, so pricing its outline against the whole file (one 184 kB outline made up 95.6% of a trial's headline) says nothing about what the index saves on code.
        public var markdownShare: Measured? {
            split.markdown
        }

        /// ``measured`` divided between code and Markdown, each name classified by ``MarkdownOutline/names(_:)``.
        ///
        /// A call that recorded `parts` is divided part by part, each keeping its own source, and the served bytes (recorded for the call, not per part) are shared out in proportion to the sources. A call without parts is read name by name from its whitespace-separated targets and is Markdown only if every name is; otherwise it is code.
        private var split: (code: Measured?, markdown: Measured?) {
            guard let measured else { return (nil, nil) }
            let total = parts.reduce(0) { $0 + ($1.source ?? 0) }
            if !parts.isEmpty, total > 0 {
                let documents = parts.filter { MarkdownOutline.names($0.target) }
                let code = parts.filter { !MarkdownOutline.names($0.target) }
                let documentSource = documents.reduce(0) { $0 + ($1.source ?? 0) }
                let documentServed = measured.served * documentSource / total
                return (
                    code.isEmpty ? nil : Measured(served: measured.served - documentServed, source: code.reduce(0) { $0 + ($1.source ?? 0) }),
                    documents.isEmpty ? nil : Measured(served: documentServed, source: documentSource)
                )
            }
            let names = targets.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            if !names.isEmpty, names.allSatisfy(MarkdownOutline.names) {
                return (nil, measured)
            }
            return (measured, nil)
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
            parts = (object["parts"] as? [[String: Any]] ?? []).compactMap { part in
                (part["target"] as? String).map { Part(target: $0, source: part["srcBytes"] as? Int) }
            }
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
            intercepted = object["intercepted"] as? String
            call = object["call"] as? String
            readBytes = object["readBytes"] as? Int
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
        /// The compressing calls and the passthrough calls, each with its own arithmetic — empty when every priced call fell on one side, where a second row would only restate the total.
        public let split: [Row]

        /// Every priced call in scope, both sides summed.
        public let total: Row

        /// Every call in scope, priced or not.
        public let calls: Int

        /// The calls in scope no saving is claimed for, Markdown outlines apart, or `nil` when there is none.
        public let unpriced: Unpriced?

        /// How much of the priced saving is work a subagent did, and how many subagents did it — `nil` when none of the priced calls carries a caller.
        ///
        /// A *floor within a floor*, and the wording says so where it is printed: only calls a hook was present for carry an agent at all.
        public let subagents: Attributed?

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

        /// What the figure was priced on, in the words every face states it: `on 3 intercepted reads (file or window asked for − answer served); 28 other calls unpriced`.
        public var sentence: String {
            let readAnyway = unpriced?.readAnyway ?? 0
            let others = (unpriced?.calls ?? 0) - readAnyway
            let clauses = [
                readAnyway > 0 ? "\(readAnyway) read anyway" : nil,
                others > 0 ? "\(others) other call\(others == 1 ? "" : "s") unpriced" : nil,
            ].compactMap(\.self)
            let tail = clauses.isEmpty ? "" : "; " + clauses.joined(separator: ", ")
            return "on \(measured) intercepted read\(measured == 1 ? "" : "s") (\(TokenEstimate.baseline))\(tail)"
        }

        /// The saving as the reader prices it — `~2.1k tokens saved` — or `nil` where the priced answers cost more than what was asked for, where "saved" would be a lie.
        public var savedText: String? {
            total.saved > 0 ? TokenEstimate.saved(bytes: total.saved) : nil
        }

        /// What the estimate was made from — `8.4 kB gross at 4 bytes a token` — or `nil` when there is no saving to explain.
        public var savedBasis: String? {
            total.saved > 0 ? TokenEstimate.basis(bytes: total.saved) : nil
        }

        /// The headline every face leads with: the priced figure and its scope in one line, so it is never quoted without what it was priced on — `~2.1k tokens saved on 3 intercepted reads (file or window asked for − answer served); 28 other calls unpriced — 8.4 kB gross at 4 bytes a token`.
        public var headline: String {
            guard let savedText, let savedBasis else { return "no saving \(sentence): \(total.outcome)" }
            return "\(savedText) \(sentence) — \(savedBasis)"
        }
    }
}

public extension UsageScan.Entry {
    /// What the log recorded for each name of a split target: the name, and the source its own answer stood in for where it has one.
    struct Part: Sendable, Equatable {
        public let target: String
        public let source: Int?
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

    /// The measured Markdown calls, reported beside the saving and not in it.
    struct Markdown: Sendable, Equatable {
        public let row: Row

        /// The line both faces print: what was served for how much document, with no claim of a saving.
        public var note: String {
            "Markdown outlines: \(row.calls) call\(row.calls == 1 ? "" : "s"), \(ByteSize.short(row.served)) served "
                + "for \(ByteSize.short(row.source)) of documents"
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

    /// The calls whose saving is not priced, and how much of what they served is on the record.
    struct Unpriced: Sendable, Equatable {
        public let tools: [String]
        public let calls: Int

        /// How many of them failed: a refusal stands in for nothing at all.
        public let failed: Int

        /// How many of them recorded what they served, and the sum of it — a served size needs no counterfactual.
        public let recorded: Int
        public let served: Int

        /// How many of them are hook answers logged before the field that prices one, which therefore cannot be told from a grep and are not priced either.
        public let unlabelled: Int

        /// How many of them the hook answered in place and the context then read anyway, so they saved nothing.
        public let readAnyway: Int

        /// The line the faces print beside the count.
        public var note: String {
            let single = calls == 1
            var note = "\(tools.spelled) call\(single ? "" : "s") unpriced — nothing observed to price \(single ? "it" : "them") against"
            if recorded > 0 {
                note += recorded < calls ? "; \(recorded) of them served \(ByteSize.short(served))" : "; \(single ? "it" : "they") served \(ByteSize.short(served))"
            }
            if failed > 0 {
                note += "; \(failed) failed"
            }
            if unlabelled > 0 {
                note += "; \(unlabelled) of them hook answers logged before the field that prices one"
            }
            if readAnyway > 0 {
                note += "; \(readAnyway) answered in place by the hook and then read anyway"
            }
            return note
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
