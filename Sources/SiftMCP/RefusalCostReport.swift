//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What the advice hook's refusals cost, as `sift audit` reports it.
///
/// Its own type because it is its own subject. The audit's body reports what the lookups were; this reports what the *advice* cost — the round trips the lone refusals took, what each next call turned out to be, where they happened, the shapes re-run unchanged, and the days they landed on — which is a different measurement over the same scans, and one that has grown a section every time a new question was asked of the refusals.
struct RefusalCostReport {
    /// What the refusals cost: the round trips of those alone in their turn, priced by what each next turn re-sent, and the costliest few with the context each was given in.
    ///
    /// A refusal's own text is a few hundred bytes, so pricing it by that says nothing. What it costs is the turn it takes to act on — and a turn re-sends the whole context, which is anything from tens of thousands of tokens early in a session to most of a million late in one. So each is priced by its own round trip, measured from the harness's `message.usage` rather than estimated, and the costliest are listed because two refusals of one text are not the same event at two sizes of context. A refusal that shared its turn cost no round trip of its own, and a lookup answered in the refusal's place cost none.
    static func section(_ scans: [TranscriptAudit.Scan], totals: TranscriptTally, redactor: Redactor?) -> [String] {
        guard totals.refusals > 0 else { return [] }
        let plural = totals.refusals == 1 ? "refusal" : "refusals"
        var lines = [
            "",
            "\(totals.refusals) \(plural), \(totals.soloRefusals) alone in \(totals.refusals == 1 ? "its" : "their") turn — each of those cost a round trip that re-sent the whole context:",
        ]
        let cost = scans.flatMap(\.roundTrips).reduce(into: RoundTripCost()) { $0 += $1.cost }
        lines.append(
            "  \(tokens(cost.inputEquivalentTokens)) input-equivalent re-sent (\(tokens(cost.rawTokens)) raw: " +
                "\(tokens(cost.uncachedInputTokens)) uncached, \(tokens(cost.cacheReadTokens)) cache reads, " +
                "\(tokens(cost.cacheWrite5mTokens + cost.cacheWrite1hTokens)) cache writes) — each next turn's " +
                "input, cache reads and cache writes, from its message.usage"
        )
        lines.append("  (uncached ×1, cache read ×0.1, cache write ×1.25 [5-minute] / ×2 [1-hour] — a price comparison against the uncached input rate, not a token count)")
        let uncharged = totals.refusals - totals.soloRefusals
        if uncharged > 0 {
            lines.append("  \(uncharged) not charged one: shared a turn with other calls, or were the context's last word")
        }
        if totals.answered > 0 {
            lines.append("  \(totals.answered) more answered in a refusal's place, costing none")
        }
        let costliest = scans
            .flatMap { scan in scan.roundTrips.map { (cost: $0.cost, label: scan.label, day: $0.day) } }
            .sorted { $0.cost.inputEquivalentTokens > $1.cost.inputEquivalentTokens }
            .prefix(5)
        if !costliest.isEmpty {
            lines.append("  costliest:")
            for entry in costliest {
                let label = redactor.map { TranscriptAudit.redacted(label: entry.label, by: $0) } ?? entry.label
                lines.append("    \(TranscriptAudit.column(tokens(entry.cost.inputEquivalentTokens), 18))\(label)\(entry.day.map { " · \($0)" } ?? "")")
            }
        }
        lines.append(contentsOf: followUpSection(totals))
        lines.append(contentsOf: whereSection(scans))
        lines.append(contentsOf: reRunSection(scans, redactor: redactor))
        lines.append(contentsOf: perDaySection(scans))
        return lines
    }

    /// What a lone refusal's next tool call turned out to be — a count and the input-equivalent tokens for each class, re-run first since that is the one the refusal bought nothing on.
    private static func followUpSection(_ totals: TranscriptTally) -> [String] {
        guard totals.soloRefusals > 0 else { return [] }
        var lines: [String] = []
        if !totals.reRunFollowUp.isEmpty {
            lines.append("  \(totals.reRunFollowUp.count) re-run unchanged — the refusal bought nothing: \(tokens(totals.reRunFollowUp.inputEquivalentTokens)) input-equivalent")
        }
        if !totals.indexFollowUp.isEmpty {
            lines.append("  \(totals.indexFollowUp.count) redirected to the index: \(tokens(totals.indexFollowUp.inputEquivalentTokens)) input-equivalent")
        }
        if !totals.otherFollowUp.isEmpty {
            lines.append("  \(totals.otherFollowUp.count) went on to something else: \(tokens(totals.otherFollowUp.inputEquivalentTokens)) input-equivalent")
        }
        if !totals.endedFollowUp.isEmpty {
            lines.append("  \(totals.endedFollowUp.count) with nothing after them — the context ends on the round trip: \(tokens(totals.endedFollowUp.inputEquivalentTokens)) input-equivalent")
        }
        return lines
    }

    /// Lone refusals split by where they happened: the main context, a subagent holding sift's tools, a subagent whose whole tool list is on record without them, and — only when there is one — a subagent with no tool list on record at all.
    ///
    /// The last two are not the same claim. A tool list recorded whole and missing sift is the harness's own word that the subagent never held it; a subagent with no tool list on record at all (``TranscriptTally/recordsWholeToolList``) has never had that settled either way, and counting it among those that "never did" hold the tools would say more than the transcript does.
    private static func whereSection(_ scans: [TranscriptAudit.Scan]) -> [String] {
        let withRoundTrips = scans.filter { !$0.roundTrips.isEmpty }
        guard !withRoundTrips.isEmpty else { return [] }
        let main = withRoundTrips.filter { !$0.isSubagent }.reduce(0) { $0 + $1.roundTrips.count }
        let subagents = withRoundTrips.filter(\.isSubagent)
        let subagentWithTools = subagents.filter(\.heldIndexTools).reduce(0) { $0 + $1.roundTrips.count }
        let subagentWithoutTools = subagents
            .filter { !$0.heldIndexTools && $0.tally.recordsWholeToolList }
            .reduce(0) { $0 + $1.roundTrips.count }
        let subagentWithNoToolListOnRecord = subagents
            .filter { !$0.heldIndexTools && !$0.tally.recordsWholeToolList }
            .reduce(0) { $0 + $1.roundTrips.count }
        var line = "  where: \(main) in the main context, \(subagentWithTools) in a subagent holding sift's tools, " +
            "\(subagentWithoutTools) in a subagent that never did"
        if subagentWithNoToolListOnRecord > 0 {
            line += ", \(subagentWithNoToolListOnRecord) in a subagent with no tool list on record"
        }
        return [line]
    }

    /// The shapes of the refused calls a lone re-run followed, worst first, then each shape again in descending count with a couple of example calls apiece — verbatim, redacted the way a file or symbol name is everywhere else in this report.
    ///
    /// A top-N over exact call text was here before: useless once nothing repeats, since which ten rows surface is arbitrary and the largest bucket, `other`, stayed opaque. Per shape instead, so every bucket is accounted for and `other` names the tool the classifier actually saw (``RefusedCallShapeClassifier``'s `Read`/`Grep`/`Glob`/`Bash` entry points), the one structure a call matching none of ``RefusalShape``'s named patterns still carries.
    private static func reRunSection(_ scans: [TranscriptAudit.Scan], redactor: Redactor?) -> [String] {
        let reRuns = scans.flatMap(\.reRunFollowUps)
        guard !reRuns.isEmpty else { return [] }
        var lines = ["  re-run shapes:"]
        let byShape = Dictionary(grouping: reRuns, by: \.shape)
        for shape in RefusalShape.allCases {
            guard let group = byShape[shape], !group.isEmpty else { continue }
            lines.append("    \(TranscriptAudit.pad(group.count)) \(shape.rawValue)")
        }
        lines.append("  re-run examples, most repeated shape first:")
        let ranked = byShape
            .map { (shape: $0.key, group: $0.value) }
            .sorted { ($0.group.count, $0.shape.rawValue) > ($1.group.count, $1.shape.rawValue) }
        for entry in ranked {
            lines.append("    \(entry.shape.rawValue) (\(entry.group.count))\(entry.shape == .other ? otherSubShapes(entry.group) : ":")")
            for call in exampleCalls(entry.group) {
                let displayed = redactor.map { TranscriptAudit.CallRedaction.redactedCall(call, by: $0) } ?? TranscriptAudit.CallRedaction.collapsingNewlines(call)
                lines.append("      \(displayed)")
            }
        }
        return lines
    }

    /// The tool named in a re-run's own text, the one bit of structure a call still carries even when it matched none of ``RefusalShape``'s patterns — `Read`, `Grep`, `Glob` or `Bash`, exactly as ``RefusedCallShapeClassifier``'s three entry points name it, read back off the text's own first word rather than re-derived, since a `RefusedCallShape` keeps `kind` but not `tool` once it is folded into a ``TranscriptAudit/ReRunFollowUp``.
    private static func tool(ofReRunCall call: String) -> String {
        let first = call.split(separator: " ", maxSplits: 1).first.map(String.init) ?? call
        return first.hasSuffix(":") ? String(first.dropLast()) : first
    }

    /// The `other` bucket's own line suffix: which tool each of its calls came in as, since that is the only classification left once none of ``RefusalShape``'s named patterns matched — or, where every one of them shares a tool, a line saying so plainly rather than a breakdown that would show nothing.
    private static func otherSubShapes(_ group: [TranscriptAudit.ReRunFollowUp]) -> String {
        let counts = Dictionary(grouping: group, by: { tool(ofReRunCall: $0.call) }).mapValues(\.count)
        guard counts.count > 1 else {
            let only = counts.keys.first ?? "a"
            return " — unclassified: every one a plain \(only) call the classifier's rules did not name"
        }
        let breakdown = counts
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        return " — by tool: \(breakdown)"
    }

    /// Two example calls from a shape's group, most recent first: the group reversed before a stable sort by day, so calls with no day recorded, or a day tied with others, keep the later encounter order rather than the earlier — the closest this data gets to "most recent" absent a finer timestamp.
    private static func exampleCalls(_ group: [TranscriptAudit.ReRunFollowUp]) -> [String] {
        Array(group.reversed())
            .sorted { ($0.day ?? "") > ($1.day ?? "") }
            .prefix(2)
            .map(\.call)
    }

    /// One line per day: how many lone refusals landed on it, and how many of those were a re-run — the count a hook fix should be read against, since a falling re-run count on the days after it is the fix working.
    private static func perDaySection(_ scans: [TranscriptAudit.Scan]) -> [String] {
        var soloByDay: [String: Int] = [:]
        for entry in scans.flatMap(\.roundTrips) {
            guard let day = entry.day else { continue }
            soloByDay[day, default: 0] += 1
        }
        var reRunByDay: [String: Int] = [:]
        for entry in scans.flatMap(\.reRunFollowUps) {
            guard let day = entry.day else { continue }
            reRunByDay[day, default: 0] += 1
        }
        let days = Set(soloByDay.keys).union(reRunByDay.keys).sorted()
        guard !days.isEmpty else { return [] }
        var lines = ["  per day:"]
        for day in days {
            let solo = soloByDay[day] ?? 0
            lines.append("    \(day)  \(solo) lone refusal\(solo == 1 ? "" : "s"), \(reRunByDay[day] ?? 0) re-run")
        }
        return lines
    }

    /// A count of tokens as the harness measured it, grouped in thousands: `701,234 tokens`.
    private static func tokens(_ count: Int) -> String {
        let digits = Array(String(count))
        let grouped = digits.enumerated().map { index, digit in
            index > 0 && (digits.count - index) % 3 == 0 ? ",\(digit)" : "\(digit)"
        }
        return grouped.joined() + " token\(count == 1 ? "" : "s")"
    }
}
