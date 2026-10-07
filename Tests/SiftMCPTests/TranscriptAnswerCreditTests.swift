//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers what an index call's *answer* locates, as distinct from what its arguments name.
///
/// `search` is the reason this exists: it is asked in `field:value` terms that name no file, so a ranged read of what it found would score as a lookup that went around the index unless the answer is read too.
struct TranscriptAnswerCreditTests {
    /// A `search` is asked in `field:value` terms and answers in `file:line` locations, so the file it located is knowable only from the answer — and without it the ranged read that took those lines scores as a miss.
    ///
    /// Scored that way, it rounds in the one direction the share must never round: the loop the guidance pushes hardest, counted as going around the index.
    @Test
    func aRangedReadOfAFileTheAnswerLocatedIsGuided() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__search", id: "s1", input: ["query": "name:Field kind:enum"]),
            TranscriptFixture.indexAnswer(id: "s1", text: "Sources/SiftCore/StructuralQuery.swift:\n  :110-163  StructuralQuery.Field — enum Field"),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/SiftCore/StructuralQuery.swift", "offset": 95, "limit": 120]),
        ])

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/SiftCore/StructuralQuery.swift")])
    }

    /// The answer locates lines, not the whole file: reading it end to end afterwards still went around the index, and crediting that would let the search excuse the very read it was meant to replace.
    @Test
    func aWholeFileReadAfterTheAnswerLocatedItIsStillAMiss() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__search", id: "s1", input: ["query": "name:Field kind:enum"]),
            TranscriptFixture.indexAnswer(id: "s1", text: "Sources/SiftCore/StructuralQuery.swift:\n  :110-163  StructuralQuery.Field"),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/SiftCore/StructuralQuery.swift"]),
        ])

        #expect(lookups == [.indexed, .cold(file: "/repo/Sources/SiftCore/StructuralQuery.swift", missed: nil)])
    }

    /// A file the answer never named is not located by it — the credit has to follow what the index actually said, or every call would excuse every read that came after it.
    @Test
    func aFileTheAnswerDidNotNameIsStillCold() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__search", id: "s1", input: ["query": "name:Field kind:enum"]),
            TranscriptFixture.indexAnswer(id: "s1", text: "Sources/SiftCore/StructuralQuery.swift:110-163"),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/SiftCore/DigestRenderer.swift", "offset": 40, "limit": 20]),
        ])

        #expect(lookups == [.indexed, .cold(file: "/repo/Sources/SiftCore/DigestRenderer.swift", missed: nil)])
    }

    /// A failed call locates nothing, and its answer must still reach the failure count rather than being read for file names.
    ///
    /// It also leaves the numerator: `share` is the index's share of the lookups it *answered*, so a session whose only call errored and whose only read went around the index would otherwise report 50% served while the index had served nothing.
    @Test
    func aFailedCallLocatesNothingAndIsNotCountedAsServed() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__search", id: "s1", input: ["query": "conforms:Codable"]),
            TranscriptFixture.toolResult(id: "s1", isError: true),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/SiftCore/StructuralQuery.swift", "offset": 95, "limit": 120]),
        ])

        #expect(tally.failed == 1)
        #expect(tally.cold == 1)
        #expect(tally.guided == 0)
        #expect(tally.indexed == 0)
        #expect(tally.share == 0)
    }

    /// Every way a digest can come back without answering: declined at the prompt, never delivered, not ruled on in time, and failed at the server.
    static let unansweredDigests = [
        TranscriptScanTests.declinedCallError,
        TranscriptScanTests.undeliveredCallErrors[0],
        TranscriptScanTests.permissionTimeoutError,
        "no repository is indexed at that root",
    ]

    /// A digest that never answered located nothing, so the ranged read after it is a first touch like any other.
    ///
    /// Credited when the call was made, it scored the read guided and took a miss out of the share on an answer that never came — even in a context that held no sift at all.
    @Test(arguments: unansweredDigests)
    func aDigestThatNeverAnsweredDoesNotGuideTheReadAfterIt(error: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Units"]),
                TranscriptFixture.toolResult(id: "d1", isError: true, text: error),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Units.swift", "offset": 10, "limit": 20]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/Units.swift", missed: nil)])
    }

    /// Nor is the whole read after it a read after its digest: there was no digest to read around.
    @Test(arguments: unansweredDigests)
    func aDigestThatNeverAnsweredIsNotTheDigestAWholeReadWentAround(error: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Units"]),
                TranscriptFixture.toolResult(id: "d1", isError: true, text: error),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Units.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/Units.swift", missed: nil)])
    }

    /// The same digest answered does guide the read, so what moved above is the answer and nothing else.
    @Test
    func theSameDigestAnsweredGuidesTheReadAfterIt() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("Units", id: "d1", file: "Units.swift") + [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Units.swift", "offset": 10, "limit": 20]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/Units.swift")])
    }

    /// The parse-error and guessed-module banners name real `.swift` paths to say the answer may be *wrong* about them — read them directly.
    ///
    /// Crediting that read as guided would let the index's own admission of doubt raise its share, because `guided` leaves `total` while `cold` does not. That is the one direction this metric must never round.
    @Test
    func aFileNamedOnlyByAWarningBannerIsNotLocated() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]),
            TranscriptFixture.indexAnswer(id: "d1", text: """
            ⚠ parse errors — members may be missing from: Sources/App/Broken.swift
            SummaryState — Sources/App/SummaryState.swift:10-90
            """),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/Broken.swift", "offset": 1, "limit": 40]),
        ])

        #expect(lookups == [.indexed, .cold(file: "/repo/Sources/App/Broken.swift", missed: nil)])
    }

    /// The sites a refused `where` lists by name match are leads, not locations, so a read of a file only they named stays cold.
    ///
    /// Nothing the index resolved led the read there. The declaration the same answer resolved still credits its file. Credited, a same-named local in unrelated code scored the read that followed it as guided, and took a miss out of the share on the strength of a text match.
    @Test
    func aFileNamedOnlyByTheNameMatchedSitesIsNotLocated() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "signedTrend"]),
            TranscriptFixture.indexAnswer(id: "w1", text: """
            tree: App  head: 0000000  dirty: 1  parse_errors: 0  semantic: stale (1 file changed since last build)
            where signedTrend
            mode: syntactic + semantic (index store via .build)

            declarations (1):
              App.Trend.signedTrend — var — var signedTrend: Double — Sources/App/Trend.swift:12-20
            callers: refused — build the project, then retry.

            syntactic call sites — by written name over the working tree, never stale; a name is not a symbol, so verify a hit — see sift help answers (call sites)

            "signedTrend" (2 uses in 2 files — for App.Trend.signedTrend):
              Sources/App/SummaryCard.swift:42  in SummaryCard.body
              Sources/App/Trend.swift:30  in Trend.render()
            """),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/SummaryCard.swift", "offset": 40, "limit": 10]),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/Trend.swift", "offset": 10, "limit": 12]),
        ])

        #expect(lookups == [
            .indexed,
            .cold(file: "/repo/Sources/App/SummaryCard.swift", missed: nil),
            .guided(file: "/repo/Sources/App/Trend.swift"),
        ])
    }

    /// The name-matched block ends where the answer's next section opens, so the declarations listed after it — a type's extensions — still credit their files.
    @Test
    func theSectionAfterTheNameMatchedSitesStillLocates() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "Gizmo"]),
            TranscriptFixture.indexAnswer(id: "w1", text: """
            syntactic call sites — by written name over the working tree, never stale; a name is not a symbol.

            "Gizmo" (1 call site in 1 file — for App.Gizmo):
              Sources/App/SummaryCard.swift:42  in SummaryCard.body

            extensions of Gizmo (1):
              extension Gizmo — 2 members — Sources/App/Catalogue.swift:1-9
            """),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Catalogue.swift", "offset": 1, "limit": 9]),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/SummaryCard.swift", "offset": 40, "limit": 10]),
        ])

        #expect(lookups == [
            .indexed,
            .guided(file: "/repo/Sources/App/Catalogue.swift"),
            .cold(file: "/repo/Sources/App/SummaryCard.swift", missed: nil),
        ])
    }

    /// A below-floor digest serves the file's own source, so the answer can contain string literals that merely *mention* a `.swift` path — and a neighbouring extension is not the file either.
    @Test
    func textThatOnlyMentionsASwiftPathLocatesNothing() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Tiny"]),
            TranscriptFixture.indexAnswer(id: "d1", text: """
            guard path.hasSuffix(".swift") else { return nil }
            let fixture = "Fixtures/Sample.swiftinterface"
            """),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/Sample.swift", "offset": 1, "limit": 20]),
        ])

        #expect(lookups == [.indexed, .cold(file: "/repo/Sources/App/Sample.swift", missed: nil)])
    }

    /// Two paths joined by a bare comma are one whitespace token, and taking only the first `.swift` in it would drop every location after the comma.
    ///
    /// The separator has to be split on, not merely tolerated at the end of a token: with a space after the comma this passes whatever the code does, so the comma here stands bare.
    @Test
    func locationsJoinedByABareCommaAreAllLocated() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__search", id: "s1", input: ["query": "kind:struct"]),
            TranscriptFixture.indexAnswer(id: "s1", text: "Sources/App/First.swift,Sources/App/Second.swift"),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/Second.swift", "offset": 10, "limit": 5]),
        ])

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/Second.swift")])
    }
}
