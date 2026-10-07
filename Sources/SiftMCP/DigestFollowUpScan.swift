//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Attributes each ranged read back to the digest member it took.
///
/// Kept out of `TranscriptScan` deliberately. That scanner's byte pre-filter is built to skip digest *answers*; this one reads them. The audit is human-invoked and can afford the second pass, and keeping them apart means the two can still never disagree about what a miss is.
public struct DigestFollowUpScan {
    private var pendingDigests: [String: [String]] = [:]
    private var pendingReads: Set<String> = []
    private var members: [String: [DigestMember]] = [:]

    private let since: Date?
    private let until: Date?
    private let day: (Date) -> String?

    public private(set) var result = DigestFollowUp()

    /// `since`/`until` bound the *reads* attributed, never the digests folded.
    ///
    /// Both halves matter and they pull opposite ways. A digest made before the window is still what a read inside it is being judged against, so dropping it would leave that read unattributable rather than merely uncounted. But a read from three days ago printed under a header reading "since today" is the exact misreading `TranscriptAudit` exists to prevent, one section lower down the same report. `until` cuts the same way at the other edge: exclusive, a read timestamped on it falls outside.
    ///
    /// `day` formats the local day a collapsed finding carries — injected so the audit's one day formatter stays the only one.
    public init(since: Date? = nil, until: Date? = nil, day: @escaping (Date) -> String? = { _ in nil }) {
        self.since = since
        self.until = until
        self.day = day
    }

    /// Folds one transcript line in.
    public mutating func consume(line: Data) {
        guard line.count > 2, mayContribute(line) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else {
            return
        }

        let stamp = object["timestamp"] as? String
        let instant = stamp.flatMap(TranscriptScan.instant)
        let reported = (since.map { start in instant.map { $0 >= start } ?? true } ?? true)
            && (until.map { end in instant.map { $0 < end } ?? true } ?? true)

        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                consume(toolUse: block, reported: reported, stamp: stamp)
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                if pendingReads.remove(id) != nil {
                    continue
                }
                guard let stems = pendingDigests.removeValue(forKey: id) else { continue }
                let parsed = DigestAnswer.members(in: text(of: block["content"]))
                guard !parsed.isEmpty else { continue }
                for stem in stems {
                    members[stem] = parsed
                }
            default:
                continue
            }
        }
    }

    private mutating func consume(toolUse block: [String: Any], reported: Bool, stamp: String?) {
        guard let name = block["name"] as? String, let id = block["id"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]

        if name.hasSuffix("__digest") {
            // Every stem the target could mean, not one of them. `locatedNames` returns a *set*, and a
            // qualified target has two members — `digest Module.Type` yields {Module, Type} — so picking
            // `.first` would pick at random: `Hasher` is seeded per process, and the same transcript would
            // attribute a different number of reads on each run of the same binary. Filing the answer under
            // both is deterministic and strictly more likely to match the read that follows.
            let stems = TranscriptScan.locatedNames(in: input, tool: "digest")
            guard !stems.isEmpty else { return }
            pendingDigests[id] = stems.sorted()
            return
        }

        guard LookupTool.rule(for: name) == "Read",
              let path = LookupTool.readPath(in: input), path.hasSuffix(".swift"),
              let listed = members[TranscriptScan.stem(ofPath: path)]
        else {
            return
        }
        pendingReads.insert(id)

        // Only a *ranged* read says what was wanted. A whole-file read took everything and names nothing.
        let offset = (input["offset"] as? NSNumber)?.intValue
        let limit = (input["limit"] as? NSNumber)?.intValue
        guard offset != nil || limit != nil, reported else { return }
        attribute(low: offset ?? 1, limit: limit, among: listed, stamp: stamp)
    }

    private mutating func attribute(low: Int, limit: Int?, among listed: [DigestMember], stamp: String?) {
        guard let describedLow = listed.map(\.low).min(), let describedHigh = listed.map(\.high).max() else {
            result.unattributed += 1
            return
        }
        // An open-ended read (offset with no limit) runs to the end of the file; clamped to the last line the
        // digest described, both so the arithmetic below cannot overflow and because lines nothing described
        // cannot speak to which member was wanted. `covered` already read it this way.
        let wanted = limit.map { low + $0 - 1 } ?? Int.max
        let high = min(wanted, describedHigh)

        let overlapping = listed.filter { !($0.high < low || $0.low > high) }
        guard !overlapping.isEmpty else {
            // Which side of the described span it fell on is the whole classification, and position alone is
            // honest enough for it: *above* the first declaration there is nothing but the file-head doc
            // comment and the imports, and *below* the last there is what the visitor skipped — a `#if DEBUG`
            // `#Preview` block above all — or, under a type digest, a declaration the digest never claimed.
            // Reading the file to confirm would buy certainty about which of those it was, which is not a
            // distinction the row makes; what it needs to know is that no digest was ever going to record it.
            //
            // A read landing in a *gap between* described members is the remainder, and stays the defect
            // signal: the digest described lines either side of it and said nothing about these.
            if low > describedHigh || wanted < describedLow {
                result.unrecordedContent += 1
            } else {
                result.unattributed += 1
            }
            return
        }

        // Measured on the overlap, not on the read's own `limit`. Judging by the limit alone would score a read
        // of a *different* region of the file — a second type in a file digest — as having taken the whole of
        // this declaration, purely because it asked for enough lines.
        let described = describedHigh - describedLow + 1
        let covered = min(high, describedHigh) - max(low, describedLow) + 1
        guard Double(covered) < DigestFollowUp.wholeDeclarationFraction * Double(described) else {
            result.wholeDeclaration += 1
            return
        }
        // The innermost overlap decides, not the first collapsed one. A file digest lists a container *and* its
        // children, each carrying its own range, so every read of a named member also overlaps the container line
        // above it — and preferring the collapsed one would score a digest that had named and located the member as
        // having hidden it. Only the narrowest thing covering the read can say whether anything was withheld.
        //
        // "Innermost" is the *best-matching* range, not the narrowest and not the containing one — each of those
        // fails a real case. Narrowest alone lets a zero-span stored property beat the
        // collapsed enum a read plainly went for. Containment-first loses the member entirely the moment a read
        // overruns its advertised range by one line — `render :34-64` read as 34-65 — and a read a line long is
        // the loop working, so that error is both commoner and the flattering one.
        //
        // Overlap similarity settles both: the shared lines over the lines either covers.
        let innermost = overlapping.max { Self.similarity(of: $0, low: low, high: high) < Self.similarity(of: $1, low: low, high: high) }
        if let innermost, innermost.collapsed {
            result.collapsedNested += 1
            // The timestamp is parsed only here, on the rare finding that will carry a day, not on every line folded.
            result.collapsed.append(DigestFollowUp.Collapsed(name: innermost.name, day: stamp.flatMap(TranscriptScan.instant).flatMap(day)))
        } else {
            result.namedMember += 1
        }
    }

    /// How much a member's advertised range and a read's range are the same lines: the shared lines over the lines either one covers.
    ///
    /// Ties keep the first member listed, and a digest lists in source order, so the attribution stays deterministic across runs — the property a `Set.first` would cost this scan.
    private static func similarity(of member: DigestMember, low: Int, high: Int) -> Double {
        let intersection = min(member.high, high) - max(member.low, low) + 1
        let union = max(member.high, high) - min(member.low, low) + 1
        guard intersection > 0, union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func text(of content: Any?) -> String {
        if let string = content as? String {
            return string
        }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Only digest calls, reads, and the results that carry a digest answer can contribute.
    private func mayContribute(_ line: Data) -> Bool {
        for marker in Self.markers where line.range(of: marker) != nil {
            return true
        }
        return false
    }

    private static let markers: [Data] = ["__digest", "\"Read\"", "Xcode", "tool_result"].map { Data($0.utf8) }
}
