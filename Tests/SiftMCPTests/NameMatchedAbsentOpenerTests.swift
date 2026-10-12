//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the lines that open a `where` answer's name-matched block once no heading is written above it: a name's verdict that it lists no site, and a type's count line, whose sites a reader must still set apart from what the answer resolved.
///
/// An answer is read the same with the heading as without it, so a transcript recorded under the old headings and one recorded without them credit the same locations.
@Suite(.temporaryDirectories)
struct NameMatchedAbsentOpenerTests {
    /// The lines of the answer outside its name-matched block: the declaration before it and the section after it.
    private static let resolved = [
        "declarations (1):",
        "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3",
        "",
        "conformers of Gizmo (1, by written name):",
        "  App.Holder — struct — Sources/App/Holder.swift:4-9",
    ]

    /// Sites listed under the opener, a file heading that counts them and a row with its text, the shape a located list also takes.
    private static let sites = [
        "  Sources/App/Depot.swift (1):",
        "    :2  in Depot.stock()  | Gizmo()",
        "  reaching only init(size:) by their labels, with no line of their own above:",
        "    Sources/App/Shelf.swift:",
        "      :7  in Shelf.fill()  | Gizmo(size: 2)",
    ]

    /// An answer whose block opens at `opener`, with `heading` above it where one is given.
    private static func answer(_ opener: String, heading: String? = nil) -> String {
        let opening = ["declarations (1):", "  App.Gizmo — struct — Sources/App/Gizmo.swift:1-3", ""] + (heading.map { [$0, ""] } ?? [])
        return (opening + [opener] + sites + ["", "conformers of Gizmo (1, by written name):", "  App.Holder — struct — Sources/App/Holder.swift:4-9"]).joined(separator: "\n")
    }

    /// What the answer locates: the declaration's first line and the conformer's, and nothing from the block.
    private static let exactLocations: Set<ExactAnswer.Location> = [
        ExactAnswer.Location(path: "Sources/App/Gizmo.swift", line: 1),
        ExactAnswer.Location(path: "Sources/App/Holder.swift", line: 4),
    ]

    /// Each way a verdict of absence opens, as the fallback for calls and the scan for a type's uses write it.
    private static let absentVerdicts = [
        "no call spelled \"stock\" anywhere in the working tree — 2 call sites by name, 2 on other types dropped, none kept (for App.Depot.stock())",
        "no use spelled \"Gizmo\" anywhere — no construction, no member reached through it, and no annotation, generic argument, conformance, cast or attribute naming it; a string literal is not searched (for App.Gizmo):",
        "every call spelled \"Gizmo\" reaches only another initializer by its labels — 1 call site by name (for App.Gizmo.init(count:))",
        "every use spelled \"stock\" is listed above or reaches only another initializer by its labels — 2 uses by name (for App.Depot.stock)",
        "nothing spelled \"isReady\" is listed here — no use by name, 1 call passing it as isReady: to the memberwise init (for App.Gizmo.isReady)",
    ]

    /// A verdict of absence with no heading above it opens the block, so the sites indented under it are leads the hook's exactness check never counts as located.
    @Test(arguments: NameMatchedAbsentOpenerTests.absentVerdicts)
    func aVerdictOfAbsenceOpensTheBlockWithNoHeadingAboveIt(verdict: String) {
        let answer = Self.answer(verdict)

        #expect(ExactAnswer.locations(inWhereAnswer: answer) == Self.exactLocations, "\(answer)")
        #expect(NameMatchedSites.linesOutside(answer: answer).map(String.init) == Self.resolved)
    }

    /// Under a heading, as transcripts already on disk carry it, the same verdict and sites split exactly where they do without one.
    @Test(arguments: NameMatchedAbsentOpenerTests.absentVerdicts)
    func aVerdictOfAbsenceSplitsAlikeUnderAHeading(verdict: String) {
        let headed = Self.answer(verdict, heading: "syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)")

        #expect(NameMatchedSites.linesOutside(answer: headed).map(String.init) == Self.resolved)
        #expect(ExactAnswer.locations(inWhereAnswer: headed) == ExactAnswer.locations(inWhereAnswer: Self.answer(verdict)))
    }

    /// A verdict of absence after another name's count line keeps the block open, with a heading or without one, so the sites under the later name stay leads too.
    @Test(arguments: [nil, "syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)"])
    func aLaterVerdictOfAbsenceKeepsTheBlockOpen(heading: String?) {
        let opener = ["\"save\" (1 call site by written name in 1 file):", "  Sources/App/Saver.swift:", "    :3  in Saver.run()  | save()", ""].joined(separator: "\n")
        let answer = Self.answer(opener + "\n" + Self.absentVerdicts[2], heading: heading)

        #expect(NameMatchedSites.linesOutside(answer: answer).map(String.init) == Self.resolved)
        #expect(ExactAnswer.locations(inWhereAnswer: answer) == Self.exactLocations)
    }

    /// The count line a store-less `where` writes for a type opens the block once the heading above it is dropped, so the rows it lists in place of a search are never read back as located.
    @Test
    func theTypeCountLineOpensTheBlockWithNoHeadingAboveIt() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": "struct Gizmo {}\n",
            "Sources/App/Use.swift": "let first = Gizmo()\nlet second = Gizmo()\n",
        ], to: root)
        let engine = try SiftEngine(directory: root)
        let answer = try #require(try await ExactAnswer.lookup(in: engine, of: "Gizmo", freshness: engine.ensureFresh())).body
        let headless = answer.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !line.hasPrefix("syntactic uses — by written name") }
            .joined(separator: "\n")
        let uses = [ExactAnswer.Location(path: "Sources/App/Use.swift", line: 1), ExactAnswer.Location(path: "Sources/App/Use.swift", line: 2)]

        #expect(answer.contains("\"Gizmo\" (2 uses by written name in 1 file) — "), "\(answer)")
        #expect(headless.contains("  Sources/App/Use.swift (2):\n    :1  | let first = Gizmo()"), "\(headless)")
        #expect(ExactAnswer.locations(inWhereAnswer: headless).isDisjoint(with: uses), "\(headless)")
        #expect(ExactAnswer.locations(inWhereAnswer: headless) == ExactAnswer.locations(inWhereAnswer: answer))
    }
}
