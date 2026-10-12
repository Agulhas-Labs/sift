//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A month of real calls — `Fixtures/usage-log.jsonl`, provenance beside it — priced under the observed-only rule.
///
/// The capture is every voluntary `digest`, `where`, `search` and `strings` call of a month, and none of them stood in for a read anyone ran. Under the rule (Docs/Design.md §4) nothing in it is priced: the old figure on this same log, ~2.2M tokens "saved", was a sum over counterfactuals nobody observed.
@Suite(.temporaryDirectories)
struct UsageSavingsFixtureTests {
    private static func fixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "usage-log", withExtension: "jsonl", subdirectory: "Fixtures"),
            sourceLocation: sourceLocation
        )
    }

    /// No call in the capture is a hook interception, so none is priced and there is no saving to state.
    @Test
    func aMonthOfVoluntaryCallsPricesNothing() throws {
        let scan = try UsageScan.load(fileURL: Self.fixture()).get()

        #expect(scan.entries.count == 6678)
        #expect(scan.entries.compactMap(\.credited).isEmpty)
        #expect(scan.savings == nil)
    }

    /// The summary counts the calls and states no saving, and says nothing of a baseline it did not observe.
    @Test
    func theRenderedSummaryStatesNoSavingForThem() throws {
        let report = try UsageReport.render(fileURL: Self.fixture())

        #expect(!report.contains("tokens saved"))
        #expect(!report.contains("estimated savings"))
        #expect(!report.contains("leans high"))
    }

    /// The page reports the same: no saving, and no priced figure to quote.
    @Test
    func thePageStatesNoSavingEither() throws {
        let projects = try TemporaryDirectory.make("savings")
        let data = try ReportData.assemble(
            logURL: Self.fixture(),
            projectsDirectory: projects,
            roots: [],
            since: nil,
            root: nil,
            now: Date(),
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            moduleHealth: { _ in nil }
        )

        #expect(data.savings == nil)
        #expect(!ReportPage.render(data).contains("tokens saved"))
    }
}
