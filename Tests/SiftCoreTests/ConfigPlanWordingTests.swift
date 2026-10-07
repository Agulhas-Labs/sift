//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the wording of `sift init` and `sift help queries` where it states what an answer does, so the words cannot drift from the behaviour.
@Suite(.temporaryDirectories)
struct ConfigPlanWordingTests {
    @Test
    func initSaysAGuessedModuleAnswerCarriesTheBanner() throws {
        let root = try TestSources.makeTempDirectory()
        let plan = ConfigPlan.make(repoRoot: root, config: SiftConfig(), paths: ["Legacy/Widgets/Widget.swift"])

        let report = ConfigPlanRenderer.render(plan: plan, wrote: nil)

        #expect(report.contains("opens with a `⚠ module guessed` banner"), Comment(rawValue: report))
        #expect(!report.contains("nothing in those"), Comment(rawValue: report))
    }

    @Test
    func theQueriesHelpNamesTheFloorTheRefusalUses() throws {
        let body = try #require(HelpTopics.topic(named: "queries")?.body)
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(SimilarityScore.minimumCallees == 3)
        #expect(flat.contains("fewer than three calls is answered as **too thin to compare**"), Comment(rawValue: flat))
    }
}
