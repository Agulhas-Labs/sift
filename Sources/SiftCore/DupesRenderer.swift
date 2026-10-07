//
// Copyright © Agulhas Labs
//

import Foundation

/// Renders a `dupes` audit: one block per group of near-duplicate bodies, each member's locator line, and the callees that earned the group.
///
/// Written in `similar`'s voice and with its locator lines, so a member here and a hit there read the same way and `digest Type.member` confirms either.
struct DupesRenderer {
    static func render(answer: DupesAnswer) -> String {
        var lines = ["dupes " + (answer.scope.isEmpty ? "." : answer.scope.joined(separator: " "))]
        let census = answer.census
        guard census.filesScanned > 0 else {
            lines.append("no Swift file the index would read lies under \(answer.scope.joined(separator: ", ")) — name a directory or file relative to the repository root.")
            return lines.joined(separator: "\n")
        }
        let floor = SimilarRenderer.floorPhrase(at: answer.options.minimumOverlap)
            + ", sharing callees that weigh at least what \(SimilarRenderer.formatted(SimilarityScore.dupesEvidenceFloor)) names no other declaration calls would"
        guard answer.totalGroups > 0 else {
            lines.append("no pair of declarations reached \(floor) — \(population(census))")
            lines.append(caveat)
            if let note = fanOutNote(for: census) {
                lines.append(note)
            }
            return lines.joined(separator: "\n")
        }
        let offset = answer.options.offset
        let listed = switch (offset, answer.groups.count) {
        case (0, answer.totalGroups): ""
        case (_, 0): ", none listed"
        case let (_, count): ", \(offset + 1)–\(offset + count) listed"
        }
        lines.append("\(answer.totalGroups) group(s) of near-duplicate bodies at \(floor)\(listed) — \(population(census))")
        lines.append(caveat)
        if let note = fanOutNote(for: census) {
            lines.append(note)
        }
        lines.append(rule(for: answer))
        if answer.strays > 0 {
            lines.append("\(answer.strays) declaration(s) cleared the floors with a member of a group they could not join, not being close to every member, so are in no group; sift similar Type.member ranks one's own neighbours.")
        }
        guard !answer.groups.isEmpty else {
            lines.append("offset \(offset) is past the last of \(answer.totalGroups) groups — pass a smaller --offset")
            return lines.joined(separator: "\n")
        }
        var headed = false
        for group in answer.groups {
            if answer.options.testCode == .rankedLast, group.isTestOrPreview, !headed {
                headed = true
                lines.append("")
                lines.append("test and preview code, ranked after the rest:")
            }
            lines.append("")
            let weakest = group.members.count > 2 ? ", weakest \(SimilarRenderer.formatted(group.weakestOverlap))" : ""
            lines.append("  \(SimilarRenderer.formatted(group.bestOverlap))\(weakest)  \(group.members.count) declarations\(copiesPhrase(group.copies))")
            lines.append(contentsOf: group.members.map { "        " + SimilarRenderer.located($0) })
            if !group.sharedCallees.isEmpty {
                let label = group.sharedByEveryMember ? "shares" : "shares pairwise (none common to all)"
                lines.append("        \(label): " + group.sharedCallees.joined(separator: ", "))
            }
        }
        let shown = offset + answer.groups.count
        if answer.totalGroups > shown {
            lines.append("")
            lines.append("… truncated: \(answer.totalGroups - shown) more groups — pass --offset \(shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// What a group's header says of the copies among its members, or nothing where there are none.
    private static func copiesPhrase(_ copies: DupesRanking.Copies) -> String {
        switch copies {
        case .all: ", one control flow and one set of written types"
        case .some: ", some with one control flow and one set of written types"
        case .none: ""
        }
    }

    /// The population the audit compared, and what it left out before comparing.
    private static func population(_ census: DupesAnswer.Census) -> String {
        var text = "\(census.compared) declaration(s) with \(SimilarityScore.minimumCallees) or more calls compared, of \(census.withBody) with a body in \(census.filesScanned) file(s)"
        if census.underSizeFloor > 0 {
            text += "; \(census.underSizeFloor) under \(DupesRanking.sizeFloor) lines left out"
        }
        if census.testCodeLeftOut > 0 {
            text += "; \(census.testCodeLeftOut) of test and preview code left out (--no-tests)"
        }
        return text
    }

    /// How a group is formed, what the numbers beside it are, and the order groups come in.
    private static func rule(for answer: DupesAnswer) -> String {
        let tier = switch answer.options.testCode {
        case .rankedLast where answer.testOrPreviewGroups > 0:
            "; the \(answer.testOrPreviewGroups) made only of test and preview code (\(testOrPreviewMeaning)) come after the rest — --tests ranks them with it, --no-tests leaves them out"
        case .rankedLast, .leftOut: ""
        case .rankedWithTheRest: "; test and preview code ranks with the rest (--tests)"
        }
        return "a group is declarations every two of which clear the floors, joined closest pair first; the number beside each is its closest pair's shared-callee overlap, the one the floor is on, "
            + "and a group of three or more names its weakest pair's too. Groups holding copies, two or more members with one control flow and one set of written types, come first;"
            + "within that, groups rank by the lines folding one into a single body would save (every member's span but the longest) times the square of its weakest pair's full score\(tier)."
    }

    /// What counts as test and preview code, said where the answer first uses the phrase.
    private static var testOrPreviewMeaning: String {
        "test functions, SwiftUI body and previews properties, and files under a path part ending in Test(s), Mock(s), Fixture(s), Stub(s), Preview(s) or Generated, "
            + "or starting with Mock, Fixture, Stub, Preview or Generated"
    }

    /// The line naming how many compared declarations had every callee excluded by the fan-out bound, or nil where none did.
    ///
    /// Says when a thin or empty answer is the bound speaking rather than the tree: those declarations were never in a candidate pair at all.
    private static func fanOutNote(for census: DupesAnswer.Census) -> String? {
        guard census.fanOutExcluded > 0 else { return nil }
        return "\(census.fanOutExcluded) of the compared declarations named no callee within the fan-out bound of \(SimilarityScore.dupesFanOutBound) — every one of theirs was too common to propose a pair, so a thin or empty answer here is the bound speaking, not the tree."
    }

    /// What the audit does and does not promise.
    ///
    /// A lower bound from syntactic shape, for three reasons a reader has to hold: two bodies that name the same callees need not behave alike, a body that inlines what another calls shares nothing with it here, and a pair whose only shared callees are ones many declarations name is never compared at all.
    static var caveat: String {
        "syntactic shape match on written names over the working tree — never stale; a group is a lead to confirm with "
            + "digest Type.member, and the list is a lower bound, never a verdict: the same callees do not mean the same behaviour, "
            + "a body that inlines what another calls is invisible to it, and bodies sharing only callees more than "
            + "\(SimilarityScore.dupesFanOutBound) declarations name are never paired."
    }
}
