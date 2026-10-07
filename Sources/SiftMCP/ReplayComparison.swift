//
// Copyright © Agulhas Labs
//

import Foundation

/// The section `audit --replay --against` prints in place of the replay's own: the calls two hooks judged differently in one replay, by the other binary's rule and this one's, the replayed share's denominator where the two differ, and each hook's replayed share.
struct ReplayComparison {
    /// The section's lines for contexts replayed against two hooks, with the real calls behind each change where `unredacted` — a change of served call alone with its two index calls as written beside its shaped label; `sampled` says the contexts are a sample of the window's sessions, so the counts are named the sample's; `summary` drops the header, every per-transition shape list, and folds a rule's rows that differ only in which `(logged)` rule they land on into one.
    static func lines(_ contexts: [ContextReplay], unredacted: Bool = false, summary: Bool = false, sampled: Bool = false) -> [String] {
        let span = sampled ? "the sample" : "the window"
        var compared = 0
        var changes: [String: [ReplayColdCall: Int]] = [:]
        var served: [String: [String: Int]] = [:]
        var totals = TranscriptTally()
        var (ours, theirs) = (ReplayTally(), ReplayTally())
        for context in contexts {
            compared += context.compared
            for (change, calls) in context.changes {
                changes[change, default: [:]].merge(calls, uniquingKeysWith: +)
            }
            for (change, pairs) in context.servedCalls {
                served[change, default: [:]].merge(pairs, uniquingKeysWith: +)
            }
            totals += context.tally.scored
            // Out of the replay for the reason the replay section gives: a context that could not reach the index is out of the share.
            guard !context.tally.couldNotReachTheIndex else { continue }
            ours += context.replay
            theirs += context.against
        }
        var counted = changes.mapValues { $0.values.reduce(0, +) }
        if summary {
            counted = Self.foldedByLoggedRule(counted)
        }
        let differing = counted.values.reduce(0, +)
        var lines: [String] = summary ? [] : [
            "",
            "replay against another binary — every call in \(span) put to both hooks in one replay; the calls they judge differently, as its rule → this one's:",
        ]
        if differing == 0 {
            lines.append("  no difference: the two hooks judge all \(compared) calls in \(span) alike")
        } else {
            lines.append("  differ       \(TranscriptAudit.pad(differing))  of the \(compared) calls in \(span)")
            for (change, count) in counted.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                var row = "      \(TranscriptAudit.pad(count))  \(change)"
                if unredacted, let pairs = served[change] {
                    row += " — e.g. " + pairs.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(2).map { "`\(Self.clippedPair($0.key))`" }.joined(separator: " · ")
                }
                lines.append(row)
                if !summary {
                    lines += ReplayColdShapes.lines(changes[change] ?? [:], rule: change, unredacted: unredacted)
                }
            }
        }
        let (old, new) = (TranscriptReplay.denominator(totals, replay: theirs), TranscriptReplay.denominator(totals, replay: ours))
        if old != new {
            lines.append(
                "  denominator  \(old) → \(new)  the replayed share's, its → this one's (located \(theirs.located) → \(ours.located),"
                    + " unreplayable \(theirs.unreplayable) → \(ours.unreplayable), not worth \(theirs.notWorthCount) → \(ours.notWorthCount))"
            )
        }
        let (was, now) = (TranscriptReplay.numerator(totals, replay: theirs), TranscriptReplay.numerator(totals, replay: ours))
        lines.append(
            "  replayed share  \(TranscriptReplay.percent(was, old, places: 1)) → \(TranscriptReplay.percent(now, new, places: 1))  (indexed + recovered \(was) → \(now))"
        )
        if summary {
            lines.append(Self.verdict(was: (was, old), now: (now, new)))
        }
        return lines
    }

    /// The share line a gate can expect without comparing rounded percentages: `share: unchanged` only where the two fractions are equal, else `share: moved +0.3` or `share: moved -1.2`, in points to one decimal of the exact difference.
    ///
    /// A share with an empty denominator counts as zero.
    static func verdict(was: (Int, Int), now: (Int, Int)) -> String {
        let (before, after) = (was.1 == 0 ? (0, 1) : was, now.1 == 0 ? (0, 1) : now)
        // Cross-multiplied, so equality is exact rather than a floating-point coincidence.
        guard before.0 * after.1 != after.0 * before.1 else { return "  share: unchanged" }
        let points = (Double(after.0) / Double(after.1) - Double(before.0) / Double(before.1)) * 100
        return "  share: moved " + String(format: "%+.1f", points)
    }

    /// A `"<theirs> → <ours>"` pair of served calls with each side cut to ``ReplayColdShapes/width`` on its own, so a long left-hand call cannot push the right-hand one, the side that differs when a target moves, off the row.
    ///
    /// The pair is kept whole until here, so two pairs that differ only past the cut are still counted apart.
    private static func clippedPair(_ pair: String) -> String {
        guard let arrow = pair.range(of: " → ") else { return ReplayColdShapes.clipped(pair) }
        return ReplayColdShapes.clipped(String(pair[..<arrow.lowerBound])) + " → " + ReplayColdShapes.clipped(String(pair[arrow.upperBound...]))
    }

    /// `counted`, with every row of the shape `"<from> → <to> (logged)"` sharing one `from` folded into a single `"<from> → <rule> (logged)"` row summing their counts — the summary's reading of a rule that now only differs by which suppression rule it logs against.
    private static func foldedByLoggedRule(_ counted: [String: Int]) -> [String: Int] {
        var folded: [String: Int] = [:]
        for (change, count) in counted {
            guard let from = Self.loggedFoldFrom(change) else {
                folded[change, default: 0] += count
                continue
            }
            folded["\(from) → <rule> (logged)", default: 0] += count
        }
        return folded
    }

    /// The `from` side of a `"<from> → <to> (logged)"` change, or `nil` where `change` isn't that shape — a differing rule whose new side names a suppression-logged rule.
    private static func loggedFoldFrom(_ change: String) -> String? {
        guard change.hasSuffix(" (logged)"), let arrow = change.range(of: " → ") else { return nil }
        return String(change[..<arrow.lowerBound])
    }
}
