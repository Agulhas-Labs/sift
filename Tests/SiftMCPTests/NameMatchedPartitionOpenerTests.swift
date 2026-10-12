//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the two ways a `where` answer's name-matched block opens: under a heading line, as transcripts already on disk carry it, or at a name's count line saying `by written name`, with no heading above it.
///
/// Every reader of a finished answer — the hook's exactness check, the transcript scan, the located-digest credit — splits it at that block, so each is held here to reading both openings alike: a lead matched on its name is never taken for a location the answer resolved.
struct NameMatchedPartitionOpenerTests {
    /// The lines of a `where` answer outside its name-matched block: the declaration before it and the section after it.
    private static let resolved = [
        "declarations (1):",
        "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
        "",
        "conformers of Gizmo (1, by written name):",
        "  App.Holder — struct — Sources/App/Holder.swift:4-9",
    ]

    /// The block's sites, as a store-less answer lists them under a file heading that counts them.
    private static let sites = [
        "  Sources/App/Depot.swift (1):",
        "    :2  in Depot.stock()  | func stock() -> Gizmo { Gizmo() }",
        "  Sources/App/SummaryCard.swift (1):",
        "    :7  in SummaryCard.body  | Gizmo()",
    ]

    /// An answer whose block opens at its count line, with the given count line, its sites, and the resolved section after them.
    private static func countLineAnswer(_ countLine: String) -> String {
        ([
            "tree: App  head: 0000000  clean  semantic: none (no index store in this worktree)",
            "no store for uses; sites by written name; build: sift run -- swift build --build-tests (sift help worktree-index)",
            "declarations (1):",
            "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
            "",
            countLine,
        ] + sites + ["", "conformers of Gizmo (1, by written name):", "  App.Holder — struct — Sources/App/Holder.swift:4-9"]).joined(separator: "\n")
    }

    /// An answer whose block opens under `heading`, the count line below it in the form a heading's block writes it.
    private static func headingAnswer(_ heading: String) -> String {
        let opening = ["declarations (1):", "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3", "", heading, "", "\"Gizmo\" (2 uses in 2 files — for App.Gizmo):"]
        return (opening + sites + ["", "conformers of Gizmo (1, by written name):", "  App.Holder — struct — Sources/App/Holder.swift:4-9"]).joined(separator: "\n")
    }

    /// What every such answer locates: the declaration's first line and the conformer's, and nothing from the block.
    private static let exactLocations: Set<ExactAnswer.Location> = [
        ExactAnswer.Location(path: "Sources/App/Gizmo.swift", line: 1),
        ExactAnswer.Location(path: "Sources/App/Holder.swift", line: 4),
    ]

    /// A block that opens at its count line is skipped as a heading's block is, so the hook's exactness check counts none of its leads as a location — while the answer still shows them.
    @Test(arguments: [
        "\"Gizmo\" (2 uses by written name in 2 files):",
        "\"Gizmo\" (1 use by written name in 1 file):",
        "\"stock\" (2 call sites by written name in 2 files; labels narrowed):",
        "\"stock\" (1 call site by written name in 1 file):",
    ])
    func aCountLineOpensTheBlockWithNoHeadingAboveIt(countLine: String) {
        let answer = Self.countLineAnswer(countLine)

        #expect(ExactAnswer.locations(inWhereAnswer: answer) == Self.exactLocations, "\(answer)")
        #expect(ExactAnswer.shownLocations(inWhereAnswer: answer).isSuperset(of: [
            ExactAnswer.Location(path: "Sources/App/Depot.swift", line: 2),
            ExactAnswer.Location(path: "Sources/App/SummaryCard.swift", line: 7),
        ]))
    }

    /// Two names' count lines in one block: the first opens it and the second is read as part of it, so neither name's sites are located.
    @Test
    func aSecondCountLineStaysInsideTheBlock() {
        let answer = [
            "declarations (2):",
            "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
            "  App.Holder — struct — Sources/App/Holder.swift:4-9",
            "",
            "\"Gizmo\" (1 use by written name in 1 file):",
            "  Sources/App/Depot.swift (1):",
            "    :2  in Depot.stock()  | Gizmo()",
            "",
            "\"Holder\" (1 use by written name in 1 file):",
            "  Sources/App/SummaryCard.swift (1):",
            "    :7  in SummaryCard.body  | Holder()",
        ].joined(separator: "\n")

        #expect(ExactAnswer.locations(inWhereAnswer: answer) == Self.exactLocations)
    }

    /// Each heading the block has opened under still opens it, so an answer a transcript recorded under any of them is split exactly where it was: the resolved lines outside, every site inside.
    @Test(arguments: [
        "syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)",
        "syntactic uses — by written name over the working tree, never stale — see sift help answers (call sites)",
        "syntactic call sites — matched on written name over the working tree: never stale, but a name is not a symbol. Verify a specific hit before relying on it.",
    ])
    func everyHeadingStillOpensTheBlock(heading: String) {
        let answer = Self.headingAnswer(heading)

        #expect(NameMatchedSites.linesOutside(answer: answer).map(String.init) == Self.resolved)
        #expect(ExactAnswer.locations(inWhereAnswer: answer) == Self.exactLocations)
    }

    /// The transcript scan reads an answer under a heading line as it reads one opened by its count line: a read of a file only the block named is a miss, and a read of a file the section after it resolved is guided.
    @Test(arguments: [
        NameMatchedPartitionOpenerTests.headingAnswer("syntactic uses — by written name over the working tree, never stale — see sift help answers (call sites)"),
        NameMatchedPartitionOpenerTests.countLineAnswer("\"Gizmo\" (2 uses by written name in 2 files):"),
    ])
    func theTranscriptScanReadsBothOpeningsAlike(answer: String) {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "Gizmo"]),
            TranscriptFixture.indexAnswer(id: "w1", text: answer),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Holder.swift", "offset": 4, "limit": 6]),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/Depot.swift", "offset": 1, "limit": 5]),
        ])

        #expect(lookups == [
            .indexed,
            .guided(file: "/repo/Sources/App/Holder.swift"),
            .cold(file: "/repo/Sources/App/Depot.swift", missed: nil),
        ])
        #expect(LocatedDigest.files(inAnswer: answer) == ["Sources/App/Gizmo.swift", "Sources/App/Holder.swift"])
    }
}
