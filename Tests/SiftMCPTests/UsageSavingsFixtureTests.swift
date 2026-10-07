//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The savings arithmetic against a month of real calls — `Fixtures/usage-log.jsonl`, provenance beside it.
///
/// A hand-written log can only prove that the aggregation matches what its author expected the distribution to be, and the distribution *is* the finding here: three quarters of the measured calls compress, a quarter are answers the floor deliberately declined to compress, and two thirds of the log measures nothing at all. Every number below was derived from the raw capture before the splitting code existed, and is recorded in that directory's `PROVENANCE.md` so a figure tuned until it flattered itself would be visible as one.
@Suite(.temporaryDirectories)
struct UsageSavingsFixtureTests {
    private static func capture(sourceLocation: SourceLocation = #_sourceLocation) throws -> UsageScan {
        try UsageScan.load(fileURL: fixture(sourceLocation: sourceLocation)).get()
    }

    private static func fixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "usage-log", withExtension: "jsonl", subdirectory: "Fixtures"),
            sourceLocation: sourceLocation
        )
    }

    /// The whole capture, summed: the figure the tool reports, against the figure the log holds.
    @Test
    func theMeasuredTotalIsTheSumOfTheCallsThatWeighedThemselves() throws {
        let savings = try #require(try Self.capture().savings)

        #expect(savings.total.calls == 993)
        #expect(savings.total.source == 11_904_956)
        #expect(savings.total.served == 3_166_768)
        #expect(savings.total.saved == 8_738_188)
        #expect(savings.percent == 27)
        #expect(savings.calls == 6678)
    }

    /// The calls that compressed and the calls that served source are two populations, and averaging them into one ratio understates the first.
    ///
    /// This is the defect the split exists for. 73% is the honest total, but it is not the tool's compression: a quarter of the measured calls are answers the floor *decided* to serve as source, and they have nothing to save. Excluded, the same log reads 77%.
    @Test
    func theCompressingCallsAreCountedApartFromThePassthroughsAndReadHigher() throws {
        let savings = try #require(try Self.capture().savings)
        let compressed = try #require(savings.split.first { $0.label == "compressed" })
        let served = try #require(savings.split.first { $0.label == "served source" })

        #expect(compressed.calls == 756)
        #expect(compressed.source == 11_388_058)
        #expect(compressed.served == 2_563_367)
        #expect(compressed.percent == 23)
        #expect(compressed.outcome == "8.8 MB under the source (77% smaller)")

        #expect(served.calls == 237)
        #expect(compressed.calls + served.calls == savings.total.calls)
        #expect(compressed.source + served.source == savings.total.source)
        #expect(compressed.served + served.served == savings.total.served)
    }

    /// A passthrough answer costs *more* than the source it serves, and the row says so rather than rounding to nothing saved.
    ///
    /// It arrives under a freshness header and a line of arithmetic explaining why it is source rather than a digest, and those are real bytes — 86 kB of them across the capture. "Nothing saved" would round that the flattering way, which is the one direction this figure must never lean.
    @Test
    func aPassthroughRowReportsWhatItCostRatherThanASavingOfNothing() throws {
        let savings = try #require(try Self.capture().savings)
        let served = try #require(savings.split.first { $0.label == "served source" })

        #expect(served.saved == -86503)
        #expect(served.percent == 117)
        #expect(served.outcome == "86 kB more than the source itself (+17%)")
        #expect(!served.outcome.contains("saved"))
    }

    /// The digest calls that recorded nothing are stated, so a 23% capture rate is a fact rather than a subtraction the reader has to do.
    @Test
    func theDigestCallsThatRecordedNoBytesAreCountedAndTheirFailuresSeparated() throws {
        let savings = try #require(try Self.capture().savings)
        let unrecorded = try #require(savings.unrecorded)

        #expect(unrecorded.tools == ["digest"])
        #expect(unrecorded.calls == 3237)
        #expect(unrecorded.failed == 45)
        #expect(unrecorded.calls + savings.total.calls == 4230)
        #expect(unrecorded.note.hasPrefix("digest calls recorded no bytes — 45 failed;"))
    }

    /// The calls no denominator exists for are named and counted, and the capture predates the day they began recording what they served.
    ///
    /// 2,448 of 6,678 calls — 37% of the log — would be scored at a saving of zero by being absent from the ratio entirely. They are named here instead, and the sentence says plainly that nothing is claimed for them.
    ///
    /// Their refusals are split out for the reason the note above splits its own: a refusal replaces no source, so 71 of these stand in for nothing rather than for an unrunnable grep — and the two adjacent notes describe the same kind of call the same way.
    ///
    /// `exemplar` is still named here, and that is the point: the tool is retired but this is a real month of a log that recorded 19 of its calls, and both the set of tools and the sentence around it are read off the entries rather than off a list of names. A reader dropping a retired tool would drop 19 real calls out of a total that says out loud how many calls it was measured over.
    @Test
    func theCallsWithNoDenominatorAreNamedAndClaimNothing() throws {
        let savings = try #require(try Self.capture().savings)
        let unpriced = try #require(savings.unpriced)

        #expect(unpriced.calls == 2448)
        #expect(unpriced.tools == ["where", "search", "strings", "exemplar"])
        #expect(unpriced.recorded == 0)
        #expect(unpriced.served == 0)
        #expect(unpriced.failed == 71)
        #expect(unpriced.note.contains("no saving is claimed for them"))
        #expect(unpriced.note.contains("71 of them failed and stand in for nothing"))
        #expect(unpriced.note.hasSuffix("and none has recorded what it served"))
    }

    /// The total says out loud that it is a floor, and the summary prints the whole block in the order it was designed to be read.
    @Test
    func theRenderedBlockLeadsWithTheAbsoluteAndCallsItsTotalAFloor() throws {
        let report = try UsageReport.render(fileURL: Self.fixture())

        #expect(report.contains(
            "estimated savings — ~2.2M tokens saved (est. vs whole-file reads), 8.7 MB gross at 4 bytes a token: "
                + "digest served 27% of the source it replaced "
                + "(measured over 993 of 6678 calls — fields recorded since 2000-01-22); "
                + "priced as if each file would otherwise be read whole; a ranged read or a grep costs less, so the figure leans high\n"
        ))
        #expect(report.contains("   756  compressed     11.4 MB →   2.6 MB   8.8 MB under the source (77% smaller)"))
        #expect(report.contains("   237  served source   516 kB →   603 kB   86 kB more than the source itself (+17%)"))
        #expect(report.contains("   993  measured       11.9 MB →   3.2 MB   8.7 MB under the source (73% smaller)"))
        #expect(report.contains("  3237  digest calls recorded no bytes — 45 failed;"))
        #expect(report.contains("  2448  where, search, strings and exemplar calls stand in for a grep"))
        #expect(report.contains(
            "~2.2M tokens saved (est. vs whole-file reads) leaves out what was not weighed: only the 993 calls above were weighed, "
                + "and a lookup served before its face began logging is not in the log to weigh at all.\n"
        ))
    }

    /// The HTML page states what the summary states — same split, same caveats, same floor.
    ///
    /// One ``UsageScan`` behind both faces already stops the *numbers* diverging; this is the other half of it. A page leading with 27% beside a summary that qualifies the same figure as a floor would be two answers about one log, which is the divergence one shared scan exists to end.
    @Test
    func thePageStatesTheSameSplitAndTheSameFloorAsTheSummary() throws {
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
        let savings = try #require(data.savings)

        let page = ReportPage.render(data)

        #expect(page.contains("~2.2M tokens"))
        #expect(page.contains("8.7 MB gross at 4 bytes a token"))
        #expect(page.contains("Estimated savings"))
        #expect(page.contains(TokenEstimate.notMeasured))
        #expect(page.contains("8.8 MB under the source (77% smaller)"))
        #expect(page.contains("86 kB more than the source itself (+17%)"))
        #expect(page.contains(savings.unrecorded?.note ?? "no shortfall note"))
        #expect(page.contains(savings.unpriced?.note ?? "no unpriced note"))
        #expect(page.contains(savings.floorNote ?? "no floor note"))
    }
}
