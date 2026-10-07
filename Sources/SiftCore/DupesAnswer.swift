//
// Copyright © Agulhas Labs
//

/// What a `dupes` audit produced, as a value the renderer turns into text.
struct DupesAnswer: Sendable {
    /// The paths the audit was narrowed to, as the caller wrote them; empty for the whole tree.
    let scope: [String]
    let options: DupesOptions
    let census: Census
    /// The page of groups the options' offset asked for, at most `SimilarityScore.resultCap` of them, in rank order.
    let groups: [Group]
    /// How many groups cleared the floor in total, listed or not.
    let totalGroups: Int
    /// Of `totalGroups`, how many are made only of test and preview code.
    let testOrPreviewGroups: Int
    /// Declarations with a pair that cleared the floors but in no group, because some member of the group their partner joined was not close enough to them.
    let strays: Int
}

extension DupesAnswer {
    /// The denominators the audit is read against.
    struct Census: Sendable, Equatable {
        let filesScanned: Int
        /// Declarations with a body in the scanned files.
        let withBody: Int
        /// Declarations whose bodies make at least `SimilarityScore.minimumCallees` calls and span at least `DupesRanking.sizeFloor` lines — the population that was paired.
        let compared: Int
        /// Declarations making enough calls but spanning fewer than `DupesRanking.sizeFloor` lines, left out of the comparison.
        let underSizeFloor: Int
        /// Test and preview declarations left out because the options asked for that.
        let testCodeLeftOut: Int
        /// Of `compared`, how many named no callee within `SimilarityScore.dupesFanOutBound` — every one of theirs was too common to propose a pair.
        let fanOutExcluded: Int
    }

    /// Declarations every pair of which cleared the floors, joined closest pair first.
    struct Group: Sendable {
        /// Ordered by path then line.
        let members: [DeclarationFingerprint]
        /// The composite score of the group's closest pair.
        let bestScore: Double
        /// That same pair's shared-callee overlap — the number the floor is on, and the one printed.
        let bestOverlap: Double
        /// The lowest shared-callee overlap of any two members.
        let weakestOverlap: Double
        /// The lowest composite score of any two members — what the rank discounts by.
        let weakestScore: Double
        /// The lines folding the group into one body would save.
        let duplicatedLines: Int
        /// Whether every member is test or preview code, so the group ranks after the rest unless the options say otherwise.
        let isTestOrPreview: Bool
        /// How many members are copies by shape — one control-flow skeleton of at least `DupesRanking.shapeFloor` tokens and one set of written types, the mark a copy keeps through renamed locals — which ranks the group ahead of the rest unless none are.
        let copies: DupesRanking.Copies
        /// The callees the evidence line names, rarest first and capped.
        let sharedCallees: [String]
        /// Whether every member names `sharedCallees`, rather than only the linked pairs because no callee is common to all.
        let sharedByEveryMember: Bool

        /// What the group ranks by: `DupesRanking.weight` of its saved lines and weakest pair.
        var weight: Double {
            DupesRanking.weight(duplicatedLines: duplicatedLines, weakestScore: weakestScore)
        }
    }
}
