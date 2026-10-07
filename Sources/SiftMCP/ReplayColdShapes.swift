//
// Copyright © Agulhas Labs
//

import Foundation

/// The calls behind one still-cold rule of the replay section, collapsed by shape, so the next hook shape is chosen from what was let through.
struct ReplayColdShapes {
    /// How many shapes a rule lists before the rest are summed on one line.
    static let listed = 10

    /// The most characters a shape or an example is printed with.
    static let width = 110

    /// How many structures a rule's grouping lists before the rest are summed on one line.
    static let structuresListed = 8

    /// The lines listed under `rule` for `calls`: the commonest shapes, each with its count, how big an answer withheld over the size budget came to, and — only where `unredacted` — up to two of the real calls behind it; where shapes were summed, every call grouped by structure after them.
    ///
    /// `complete` lists every shape and every structure, summing none — the form `--shapes` writes.
    static func lines(_ calls: [ReplayColdCall: Int], rule: String, unredacted: Bool, complete: Bool = false) -> [String] {
        var groups: [String: [ReplayColdCall: Int]] = [:]
        for (call, count) in calls where count > 0 {
            groups[TranscriptAudit.CallRedaction.shape(of: call.text), default: [:]][call, default: 0] += count
        }
        let ranked = groups
            .map { (shape: $0.key, calls: $0.value, count: $0.value.values.reduce(0, +)) }
            .sorted { ($0.count, $1.shape) > ($1.count, $0.shape) }
        var lines = ranked.prefix(complete ? ranked.count : listed).map { group in
            var line = "          \(TranscriptAudit.pad(group.count))  \(complete ? group.shape : clipped(group.shape))"
            if rule == InPlaceAnswerer.Withholding.overSize.rawValue {
                line += sizeNote(group.calls)
            }
            if unredacted {
                line += " — e.g. " + examples(group.calls, complete: complete).joined(separator: " · ")
            }
            return line
        }
        let rest = ranked.dropFirst(lines.count)
        if !rest.isEmpty {
            lines.append("          \(TranscriptAudit.pad(rest.reduce(0) { $0 + $1.count }))  … \(rest.count) more shapes")
        }
        if complete || !rest.isEmpty {
            lines += structures(calls, complete: complete)
        }
        return lines
    }

    /// Every call in `calls` bucketed by the structure of its command line, commonest first: a header naming how many calls the buckets cover, then the ``structuresListed`` commonest (every one where `complete`) and the rest summed.
    static func structures(_ calls: [ReplayColdCall: Int], complete: Bool) -> [String] {
        var buckets: [String: Int] = [:]
        for (call, count) in calls where count > 0 {
            buckets[TranscriptAudit.CallRedaction.structure(of: call.text), default: 0] += count
        }
        let ranked = buckets.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let total = ranked.reduce(0) { $0 + $1.value }
        var lines = ["          by structure — all \(total) calls, the listed shapes included:"]
        lines += ranked.prefix(complete ? ranked.count : structuresListed).map { "            \(TranscriptAudit.pad($0.value))  \($0.key)" }
        let rest = ranked.dropFirst(lines.count - 1)
        if !rest.isEmpty {
            lines.append("            \(TranscriptAudit.pad(rest.reduce(0) { $0 + $1.value }))  … \(rest.count) more structures")
        }
        return lines
    }

    /// How big the answers a shape's calls were withheld over came to, against the budget, and how many stopped at the search's own ceiling before one was built.
    static func sizeNote(_ calls: [ReplayColdCall: Int]) -> String {
        let sizes = calls.keys.compactMap(\.answerBytes)
        var parts: [String] = []
        if let smallest = sizes.min(), let largest = sizes.max() {
            let span = smallest == largest ? "\(smallest)" : "\(smallest)–\(largest)"
            parts.append("answer \(span) B over the \(InPlaceAnswer.sizeBudget) B budget")
        }
        let unmeasured = calls.filter { $0.key.answerBytes == nil }.values.reduce(0, +)
        if unmeasured > 0 {
            parts.append("\(unmeasured) stopped at the search ceiling")
        }
        return parts.isEmpty ? "" : " — " + parts.joined(separator: ", ")
    }

    /// Up to two of the real calls behind a shape, commonest first, each on one line — unclipped where `complete`, the form `--shapes` writes.
    static func examples(_ calls: [ReplayColdCall: Int], complete: Bool = false) -> [String] {
        var texts: [String: Int] = [:]
        for (call, count) in calls {
            texts[TranscriptAudit.CallRedaction.collapsingNewlines(call.text), default: 0] += count
        }
        return texts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(2).map { "`\(complete ? $0.key : clipped($0.key))`" }
    }

    /// `text` cut to ``width`` characters, with an ellipsis where it was cut.
    static func clipped(_ text: String) -> String {
        text.count > width ? String(text.prefix(width - 1)) + "…" : text
    }
}
