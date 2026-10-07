//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the reader of a finished `where` answer's name-matched block against what the renderer actually writes, so the two cannot drift apart.
@Suite(.temporaryDirectories)
struct NameMatchedSitesTests {
    /// A type's answer with no store: its declaration, the name-matched calls standing in for its callers, and the extension listed after them.
    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    let size = 1\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("extension Gizmo {\n    func grow() {}\n}\n", to: "Sources/App/Catalogue.swift", in: root)
        try TestSources.write("struct Depot {\n    func stock() -> Gizmo { Gizmo() }\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Gizmo", freshness: freshness)
    }

    /// Everything the answer resolved stays — the declaration, and the extension listed after the block — and nothing the block matched by name does.
    @Test
    func theLinesOutsideTheBlockAreWhatTheAnswerResolved() async throws {
        let answer = try await Self.answer()

        let outside = NameMatchedSites.linesOutside(answer: answer).joined(separator: "\n")

        #expect(answer.contains("\n  Sources/App/Depot.swift (1):\n    :2  | func stock() -> Gizmo { Gizmo() }\n"))
        #expect(!outside.contains("Depot.swift"))
        #expect(!outside.contains("syntactic uses"))
        #expect(outside.contains("Sources/App/Gizmo.swift:1-3"))
        #expect(outside.contains("extensions of Gizmo (1):"))
        #expect(outside.contains("Sources/App/Catalogue.swift:1-3"))
    }

    /// The locations read off an answer skip the name-matched block and keep reading, so a resolved section written after it is located as the one before it is.
    @Test
    func aSectionAfterTheBlockIsStillLocated() {
        let answer = [
            "declarations (1):",
            "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
            "",
            "syntactic call sites — by written name (1):",
            "  Sources/App/Depot.swift:2  in Depot.stock()",
            "",
            "conformers of Gizmo (1, by written name):",
            "  App.Holder — struct — Sources/App/Holder.swift:4-9",
        ].joined(separator: "\n")

        let located = ExactAnswer.locations(inWhereAnswer: answer)

        #expect(located == [
            ExactAnswer.Location(path: "Sources/App/Gizmo.swift", line: 1),
            ExactAnswer.Location(path: "Sources/App/Holder.swift", line: 4),
        ])
    }

    /// An answer recorded before the heading was shortened still has its block skipped, so a transcript from then locates only what that answer resolved.
    @Test
    func aBlockUnderTheEarlierHeadingIsStillSkipped() {
        let answer = [
            "declarations (1):",
            "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
            "",
            "syntactic call sites — matched on written name over the working tree: never stale, but a name is not a symbol. Verify a specific hit before relying on it.",
            "  Sources/App/Depot.swift:2  in Depot.stock()",
        ].joined(separator: "\n")

        let outside = NameMatchedSites.linesOutside(answer: answer).joined(separator: "\n")

        #expect(!outside.contains("Depot.swift"))
        #expect(outside.contains("Sources/App/Gizmo.swift:1-3"))
    }

    /// An answer with no name-matched block is read whole.
    @Test
    func anAnswerWithoutTheBlockIsReadWhole() {
        let answer = "declarations (1):\n  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3\n\nconformers of Gizmo (1, by written name):\n  App.Depot — struct — Sources/App/Depot.swift:1-3"

        #expect(NameMatchedSites.linesOutside(answer: answer).joined(separator: "\n") == answer)
    }

    /// A row that closes on its access, its units or its folded sites locates its line as a bare row does, so a property read only in a file is located there.
    @Test
    func aListedRowIsLocatedWhateverItClosesOn() {
        let answer = [
            "declarations (1):",
            "  App.Depot.pending — var — public static let pending = 1 — Sources/App/Depot.swift:2",
            "",
            "reads and writes of App.Depot.pending (4):",
            "  level — Sources/App/Uses.swift:4 — read",
            "  getter:body — Sources/App/Panel.swift:16 — read via $flag",
            "  init(lamp:) — Sources/App/Panel.swift:11 — read and write  ×2 units",
            "  count() — Sources/App/Tally.swift:7 (3 sites)",
            "  sweep() — Sources/App/Gone.swift:9 — read  (file deleted since last build)",
        ].joined(separator: "\n")

        #expect(ExactAnswer.locations(inWhereAnswer: answer) == [
            ExactAnswer.Location(path: "Sources/App/Depot.swift", line: 2),
            ExactAnswer.Location(path: "Sources/App/Uses.swift", line: 4),
            ExactAnswer.Location(path: "Sources/App/Panel.swift", line: 16),
            ExactAnswer.Location(path: "Sources/App/Panel.swift", line: 11),
            ExactAnswer.Location(path: "Sources/App/Tally.swift", line: 7),
        ])
    }

    /// A reference row capped at its listed lines locates the lines it lists, and none of those it only counts.
    @Test
    func aCappedReferenceRowLocatesTheLinesItLists() {
        let answer = [
            "used by App.Gizmo: 62 references in 2 files",
            "  Sources/App/Big.swift (60): 3, 4, +58 more",
            "  Sources/App/Uses.swift (2): 3, 7",
        ].joined(separator: "\n")

        #expect(ExactAnswer.locations(inWhereAnswer: answer) == [
            ExactAnswer.Location(path: "Sources/App/Big.swift", line: 3),
            ExactAnswer.Location(path: "Sources/App/Big.swift", line: 4),
            ExactAnswer.Location(path: "Sources/App/Uses.swift", line: 3),
            ExactAnswer.Location(path: "Sources/App/Uses.swift", line: 7),
        ])
    }
}
