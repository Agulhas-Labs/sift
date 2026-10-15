//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The primer is paid in full by every session and subagent that starts in Swift, so its size is a budget, not a style (Docs/Design.md, "The primer").
///
/// A paired benchmark measured the fixed start at about 1.1k tokens for the primer before this budget; the habits it exists to name fit in a fraction of that, and the reasons behind them arrive with the rule at the first `.swift` file.
struct SessionPrimerBudgetTests {
    /// Bytes, not tokens: about four bytes a token in this prose.
    ///
    /// 900 bytes held the primer near 200 tokens until the standing caveats moved into it from every `where` and `search` answer (Docs/Design.md §2), and stayed there until they were left to the two tool descriptions and `sift help answers`; the longest primer, a subagent's pointing at the CLI, is about 1.44 kB.
    static let budget = 1550

    @Test(arguments: [SessionPrimer.Audience.session, .subagent])
    func thePrimerInsideAnIndexedRootFitsTheBudget(audience: SessionPrimer.Audience) throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: audience))

        #expect(primer.utf8.count <= Self.budget, "\(primer.utf8.count) bytes")
    }

    @Test(arguments: [SessionPrimer.Audience.session, .subagent])
    func thePrimerInAnUnindexedRepositoryFitsTheBudget(audience: SessionPrimer.Audience) throws {
        let primer = try #require(SessionPrimer.render(.unregisteredSwiftRepository("/repos/App"), audience: audience))

        #expect(primer.utf8.count <= Self.budget, "\(primer.utf8.count) bytes")
    }

    /// Where the lookup rules let the CLI run unprompted, the primer carries the longer of its two CLI sentences, so that one is held to the budget too.
    @Test(arguments: [SessionPrimer.Audience.session, .subagent])
    func thePrimerPointingAtTheCLIFitsTheBudget(audience: SessionPrimer.Audience) throws {
        for context in [SessionContext.insideRoot("/repos/App"), .unregisteredSwiftRepository("/repos/App")] {
            let primer = try #require(SessionPrimer.render(context, audience: audience, lookupsFromBash: true))

            #expect(primer.utf8.count <= Self.budget, "\(primer.utf8.count) bytes")
        }
    }

    /// The cut keeps what the primer is for: `digest` before a Swift file is opened, `where` before a grep, and the CLI where the tools are missing.
    @Test
    func theSlimPrimerStillNamesTheReadingAndSearchHabits() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App")))

        #expect(primer.contains("before reading or grepping"))
        #expect(primer.contains("`digest <Type>`"))
        #expect(primer.contains("`where <Symbol>` instead of grepping"))
        #expect(primer.contains("ranged Read"))
    }

    /// The rule is not part of the fixed start: it is path-scoped, so Claude Code loads it with the first `.swift` file and never at a session's start.
    @Test
    func theShippedRuleLoadsOnlyWithASwiftFile() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
        let rule = try String(contentsOf: root.appendingPathComponent("Sift.md"), encoding: .utf8)

        #expect(rule.hasPrefix("---\npaths:\n  - \"**/*.swift\"\n---\n"))
    }

    /// The rule is re-sent as context on every request once loaded, so its size is a budget too: the depth lives behind `sift help <topic>`.
    @Test
    func theShippedRuleStaysUnderItsSizeBudget() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
        let rule = try String(contentsOf: root.appendingPathComponent("Sift.md"), encoding: .utf8)

        #expect(rule.utf8.count <= 2600, "\(rule.utf8.count) bytes")
    }
}
