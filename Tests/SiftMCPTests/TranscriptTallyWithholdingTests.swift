//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the two counts a withheld lookup can be added to, and the rule that it is never added to both.
struct TranscriptTallyWithholdingTests {
    /// The two halves of a withholding are tallied apart, so the count that excuses a lookup says which excuse it is.
    ///
    /// A count is a question no index call answers, and the re-run of a refused search is one an index call answered so well the hook refused the search over it. Pooled on a single counter those are indistinguishable, and every rule added to the second half quietly improves a share reported under the first half's name — which is the redefinition ``TextSearch/Withholding`` exists to prevent, held here at the counting end.
    @Test
    func aWithholdingOnWorthIsTalliedApartFromTextTheIndexNeverRecords() {
        let lines = [
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["pattern": "SummaryState", "glob": "*.swift", "output_mode": "count"]),
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            TranscriptFixture.toolResult(id: "g2", isError: true, text: TranscriptFixture.refusal()),
            TranscriptFixture.toolUse("Grep", id: "g3", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ]

        #expect(TranscriptFixture.lookups(lines) == [
            .textSearch(cause: .patternNamesNothing),
            .cold(file: nil, missed: .resolve),
            .withheldOnWorth(rule: .retryAllowed),
        ])

        let tally = TranscriptFixture.tally(lines)
        #expect(tally.textSearches == 1)
        #expect(tally.withheldOnWorth == 1)
        // Both leave the share, and neither is ever added to the other's count.
        #expect(tally.total == 0)
    }

    /// The lookups the index owned and lost on a judgement of worth are counted by which rule made that judgement, because the four rules argue for four different things and pooling them into one count would hide which fix applies.
    ///
    /// One of each: a context grep, an alternation confined to the files it names, a filtered pipeline, and a refusal whose identical re-run the hook let through. The split sums to the same total the row above it has always reported, so the count cannot move by being explained.
    @Test
    func theNotWorthRowIsSplitByWhichRuleMadeTheJudgement() {
        let lines = [
            // A grep of one named file printing context around a match that is not a declaration.
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": #"grep -n "matchedLines" -A8 Sources/App/Depot.swift"#]),
            // An alternation of two or more names, confined to the file it names.
            TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": #"grep -n "waitForExit|temporaryLog" Sources/App/Depot.swift"#]),
            // A read whose output a later pipeline stage filters.
            TranscriptFixture.toolUse("Bash", id: "b3", input: ["command": "grep -rn InPlaceShape Sources --include=*.swift | sort -u"]),
            // A refusal, then its identical re-run, which the hook lets through.
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            TranscriptFixture.toolResult(id: "g1", isError: true, text: TranscriptFixture.refusal()),
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.withheldOnWorthCauses.contextLines == 1)
        #expect(tally.withheldOnWorthCauses.severalNames == 1)
        #expect(tally.withheldOnWorthCauses.filteredOutput == 1)
        #expect(tally.withheldOnWorthCauses.retryAllowed == 1)
        // A split of the row rather than a set of counters beside it: the total cannot move by being explained.
        #expect(tally.withheldOnWorth == 4)
        #expect(tally.total == 0)
    }

    /// The lookups the index never recorded are counted by what was missing, because the three causes argue for three different things and only one of them is a case for recording more than declarations.
    ///
    /// A pooled row says how many lookups the tool declined to claim and nothing about what would answer them: 152 of them is an argument for recording comment bodies, for indexing another tree, or for nothing at all, depending on a split nobody had. The advisor already tells the causes apart in order to withhold, so the split is carried from that decision rather than re-derived at the counting end, and the three still sum to the one row.
    @Test
    func textTheIndexNeverRecordedIsCountedByWhatWasMissing() {
        let lines = [
            // A count: the pattern names something, but volume is the one thing a symbol index does not measure.
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["pattern": "SummaryState", "glob": "*.swift", "output_mode": "count"]),
            // The same name swept for, where no index on this machine declares it.
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            // A whole read of a file in a tree no index holds, which no call can name.
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/Users/someone/App/.build/checkouts/Dep/Sources/Dep/Thing.swift"]),
        ]

        let tally = TranscriptFixture.tally(lines, couldAnswer: { _, _ in false })

        #expect(tally.textSearchCauses.patternNamesNothing == 1)
        #expect(tally.textSearchCauses.undeclaredName == 1)
        #expect(tally.textSearchCauses.unnameableFile == 1)
        // A split of the row rather than a set of counters beside it: the causes are what the single count
        // was all along, so the row cannot move by being explained.
        #expect(tally.textSearches == 3)
        #expect(tally.total == 0)
    }

    /// A reading stage a later stage of the same pipeline filters is the index's own answer, weaker than what was asked — the same shape as a context grep or a several-names alternation — so it lands in the withheld-on-worth half and carries no ``TextSearch/Cause`` of its own, rather than adding a fourth line under the text-search row.
    @Test
    func aFilteredPipelineIsWithheldOnWorthAndNeverATextSearch() {
        let lines = [
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -rn InPlaceShape Sources --include=*.swift | sort -u"]),
        ]

        #expect(TranscriptFixture.lookups(lines) == [.withheldOnWorth(rule: .filteredOutput)])

        let tally = TranscriptFixture.tally(lines)
        #expect(tally.withheldOnWorth == 1)
        #expect(tally.withheldOnWorthCauses.filteredOutput == 1)
        #expect(tally.textSearches == 0)
        #expect(tally.textSearchCauses.total == 0)
        #expect(tally.total == 0)
    }

    /// The share the audit prints beside the second count is the one a reader would get without it: the withheld lookups counted as the misses they are, and the index's own calls untouched.
    @Test
    func theShareWithoutTheWorthExcuseCountsThoseLookupsAsMisses() {
        let tally = TranscriptTally(indexed: 1, cold: 1, textSearchCauses: TextSearchCauses(patternNamesNothing: 3), withheldOnWorthCauses: WithholdOnWorthCauses(contextLines: 2))

        #expect(tally.shareText == "50%")
        #expect(TranscriptTally.shareTextCountingWithheldOnWorth([tally]) == "25%")
        // Text the index never recorded is no part of that arithmetic: it was never a lookup to lose.
        #expect(TranscriptTally.shareTextCountingWithheldOnWorth([TranscriptTally(indexed: 1, cold: 1, textSearchCauses: TextSearchCauses(patternNamesNothing: 3))]) == "50%")
    }

    /// A `withheldOnWorth` lookup from a context that could not reach the index at all had no choice to make, exactly as its `cold` siblings do not — so the counterfactual must exclude it the same way the ordinary share already does, rather than re-admitting it as a reachable miss once the tallies are pooled.
    @Test
    func aWithheldOnWorthLookupFromAnUnreachableContextIsExcludedFromTheCounterfactual() {
        let main = TranscriptTally(indexed: 1, cold: 1)
        let subagent = TranscriptTally(withheldOnWorthCauses: WithholdOnWorthCauses(contextLines: 10), recordedToolListWithoutIndex: true)

        #expect(subagent.couldNotReachTheIndex)
        #expect(TranscriptTally.shareTextCountingWithheldOnWorth([main, subagent]) == "50%")
    }
}
