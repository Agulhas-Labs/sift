//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A grep answered in place with a `where` counts the matching lines the answer does not show, comments above all, under the paths searched: a line the search would print is shown or counted, never dropped in silence.
@Suite(.temporaryDirectories)
struct ScopedGrepAnswerTests {
    /// Comment lines the search prints and no `where` lists are counted under the paths searched, with the way to see them, rather than left out in silence.
    @Test(arguments: ["grep -rn Gizmo Sources", "grep -rnw Gizmo Sources"])
    func commentLinesUnderTheNamedPathAreCounted(command: String) async throws {
        let root = try NoStoreSweepTests.unbuiltRepository(shopTail: "// A Gizmo is cheap.\n/// Every Gizmo is sold.\n")

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(answered.reason.contains("2 comment lines under Sources also match, not shown here — re-run the identical command to see them"), "\(answered.reason)")
        #expect(!answered.reason.contains("A Gizmo is cheap"))
    }

    /// An answer showing every line the search prints carries no such count.
    @Test
    func anAnswerShowingEveryLineCountsNothing() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))

        #expect(!answered.reason.contains("also match"))
    }

    /// An answer standing whole for a search of a subtree, with a site outside it, says it was answered across the tree and how many of the sites it shows are under the path searched.
    @Test
    func anAnswerWithSitesOutsideThePathSearchedSaysItWasWidened() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo \(NoStoreSweepTests.shelf)", in: root))

        // The declaration in Sources/App/Gizmo.swift is outside the shelf; the twenty-six uses in the shop are under it.
        #expect(answered.reason.contains("answered across the tree: 26 of 27 sites shown are under \(NoStoreSweepTests.shelf)\n"), "\(answered.reason)")
        #expect(answered.reason.contains("Sources/App/Gizmo.swift:1-3"))
    }

    /// An answer whose every site is under the path searched, or for a search naming no path short of the repository, says nothing of widening.
    @Test(arguments: ["grep -rn Gizmo Sources", "grep -rn Gizmo ."])
    func anAnswerInsideThePathSearchedSaysNothingOfWidening(command: String) async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))

        #expect(!answered.reason.contains("answered across the tree"), "\(answered.reason)")
    }

    /// The widening line counts the sites under any operand against every site shown, in the singular where one is inside, and is absent where no operand is named or every site is inside.
    @Test
    func theWideningLineCountsTheSitesUnderTheOperands() throws {
        let root = try TemporaryDirectory.make("widening")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pkg/Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pkg/Tests"), withIntermediateDirectories: true)
        let shown: Set<ExactAnswer.Location> = [
            ExactAnswer.Location(path: "Pkg/Sources/Depot.swift", line: 3),
            ExactAnswer.Location(path: "Pkg/Tests/Depot.swift", line: 7),
            ExactAnswer.Location(path: "Pkg/Tests/Depot.swift", line: 9),
        ]

        #expect(SearchOperand.widening(of: shown, by: ["Pkg/Sources"], from: root.path, inRepositoryAt: root.path) == "answered across the tree: 1 of 3 sites shown is under Pkg/Sources")
        #expect(SearchOperand.widening(of: shown, by: ["Pkg/Sources", "Pkg/Tests"], from: root.path, inRepositoryAt: root.path) == nil)
        #expect(SearchOperand.widening(of: shown, by: [], from: root.path, inRepositoryAt: root.path) == nil)
        #expect(SearchOperand.widening(of: shown, by: ["."], from: root.path, inRepositoryAt: root.path) == nil)
    }

    /// A comment-only line is told from a code line naming the name, and the note names each kind it counts, in the singular where there is one.
    @Test
    func theNoteNamesWhatItCounts() {
        #expect(UnshownGrepLines.isComment("    /// Gizmo"))
        #expect(UnshownGrepLines.isComment(" * Gizmo"))
        #expect(!UnshownGrepLines.isComment("let label = \"Gizmo\""))
        #expect(UnshownGrepLines(comments: 1, others: 2).note(under: ["Sources"]) == "1 comment line and 2 other lines no site accounts for under Sources also match, not shown here — re-run the identical command to see them")
        #expect(UnshownGrepLines(comments: 0, others: 0).note(under: ["Sources"]) == nil)
    }

    /// The line an answer carries where the lines its search prints went uncounted.
    static var notCounted: String {
        "other matching lines (comments, text) were not counted — re-run the identical command to see them"
    }

    /// Under a cut that drops lines across files whose order grep leaves unfixed, the lines handed back are every line any order prints, not what the cut keeps, so none is counted as one a re-run would show: the answer says they went uncounted.
    @Test
    func aCutThatDropsLinesCountsNoneOfThem() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository(shopTail: String(repeating: "// A Gizmo is cheap.\n", count: 46))

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources | head -60", in: root))

        #expect(!answered.reason.contains("also match"), "\(answered.reason)")
        #expect(answered.reason.contains(Self.notCounted + "\n"), "\(answered.reason)")
    }

    /// A `Grep` runs no search here, so nothing it prints is counted, and the answer says so rather than reading as though nothing else matched.
    @Test
    func aGrepToolAnswerSaysItsLinesWentUncounted() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository(shopTail: "// A Gizmo is cheap.\n")
        let tool = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Gizmo", "path": "Sources"], in: root.path))

        let outcome = try await InPlaceAnswerTests.answer(tool.call, from: tool.directory)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the Grep answered, got \(outcome)")
            return
        }

        #expect(answered.reason.contains(Self.notCounted + "\n"), "\(answered.reason)")
    }

    /// A `Grep`'s widening line names its path as the call gave it, not as it was resolved to root the answer.
    @Test
    func aGrepToolWideningNamesThePathAsGiven() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()
        let tool = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Gizmo", "path": NoStoreSweepTests.shelf], in: root.path))

        let outcome = try await InPlaceAnswerTests.answer(tool.call, from: tool.directory)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the Grep answered, got \(outcome)")
            return
        }

        #expect(answered.reason.contains("answered across the tree: 26 of 27 sites shown are under \(NoStoreSweepTests.shelf)\n"), "\(answered.reason)")
    }

    /// The index sift writes at the repository's root names every name and is binary; a search of the whole repository still counts what it prints once sift has answered there.
    ///
    /// The name is declared in a file named otherwise, since git's own binary index names every tracked file.
    @Test
    func aRootSearchIsCountedBesideSiftsOwnIndex() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/App/Things.swift": "struct Widget {}\n",
            "\(NoStoreSweepTests.shelf)/Stock.swift": NoStoreSweepTests.shop(using: "Widget") + "// A Widget is cheap.\n// Every Widget is sold.\n",
        ], to: root)
        _ = try await InPlaceAnswerTests.outcome("grep -rn Widget Sources", in: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift/index.db").path))

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Widget .", in: root))

        #expect(answered.reason.contains("2 comment lines under . also match, not shown here"), "\(answered.reason)")
    }

    /// Only sift's binary store is left out of a root search: a run log it writes beside its index is text every grep prints, so its lines naming the name are counted.
    @Test
    func aRunLogBesideSiftsOwnIndexIsCounted() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/App/Things.swift": "struct Widget {}\n",
            "\(NoStoreSweepTests.shelf)/Stock.swift": NoStoreSweepTests.shop(using: "Widget") + "// A Widget is cheap.\n// Every Widget is sold.\n",
        ], to: root)
        _ = try await InPlaceAnswerTests.outcome("grep -rn Widget Sources", in: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift/index.db").path))
        let log = root.appendingPathComponent(".sift/runs/run-1.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "error: cannot find 'Widget' in scope\nnote: Widget was renamed\n".write(to: log, atomically: true, encoding: .utf8)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Widget .", in: root))

        #expect(answered.reason.contains("2 comment lines and 2 other lines no site accounts for under . also match, not shown here"), "\(answered.reason)")
    }

    /// A doc comment is left out only where it stands directly above the declaration whose summary the answer shows: the same text over another declaration earlier in the file is counted.
    @Test
    func aDocCommentOverAnotherDeclarationIsCounted() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()
        try MCPTestRepo.add(["Sources/App/Gizmo.swift": "/// Every Gizmo is sold.\nlet countIsOne = true\n/// Every Gizmo is sold.\n" + NoStoreSweepTests.gizmo], to: root)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))

        #expect(answered.reason.contains("/// Every Gizmo is sold."), "\(answered.reason)")
        #expect(answered.reason.contains("1 comment line under Sources also matches, not shown here"), "\(answered.reason)")
    }

    /// A Markdown bullet opens on `*` as a block comment's continuation does, but outside a Swift or C-family source no line is a comment.
    @Test
    func aMarkdownBulletIsNoComment() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()
        try MCPTestRepo.add(["Sources/Notes.md": "* Gizmo is sold here.\n"], to: root)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))

        #expect(answered.reason.contains("1 other line no site accounts for under Sources also matches"), "\(answered.reason)")
        #expect(!answered.reason.contains("comment line"), "\(answered.reason)")
    }

    /// Operands one of which holds the other make grep print a line twice; it is one line, counted once.
    @Test
    func overlappingOperandsCountEachLineOnce() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository(shopTail: "// A Gizmo is cheap.\n// Every Gizmo is sold.\n")

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources Sources/App", in: root))

        #expect(answered.reason.contains("2 comment lines under Sources Sources/App also match"), "\(answered.reason)")
    }

    /// A doc comment whose summary the answer shows beside its declaration is in front of the reader, so it is not counted as a line the answer does not show.
    @Test
    func aDocCommentTheAnswerShowsIsNotCounted() async throws {
        let root = try NoStoreSweepTests.unbuiltRepository()
        try MCPTestRepo.add(["Sources/App/Gizmo.swift": "/// Every Gizmo is sold.\n" + NoStoreSweepTests.gizmo], to: root)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))

        #expect(answered.reason.contains("/// Every Gizmo is sold."), "\(answered.reason)")
        #expect(!answered.reason.contains("also match"), "\(answered.reason)")
    }

    /// Sites the answer's per-file cap cut are counted as sites past the cap, and only a line no site could be is one no site accounts for.
    @Test
    func sitesPastThePerFileCapAreNotLinesNoSiteAccountsFor() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let uses = String(repeating: "        _ = Gizmo()\n", count: 60)
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": NoStoreSweepTests.gizmo,
            "\(NoStoreSweepTests.shelf)/Shop.swift": "struct Shop {\n    func stock() {\n" + uses + "    }\n}\nlet label = \"Gizmo\"\n",
        ], to: root)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))

        #expect(answered.reason.contains("more sites past the per-file cap"), "\(answered.reason)")
        #expect(answered.reason.contains("1 other line no site accounts for"), "\(answered.reason)")
        #expect(!answered.reason.contains("31 other lines"), "\(answered.reason)")
    }

    /// A line the grep matches that no site is, past the cap among sites the grep does not match, is still a line no site accounts for: the cut sites are told by line, not by how many were cut.
    @Test
    func aLineNoSiteIsPastTheCapIsNotTakenForACutSite() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let annotated = String(repeating: "    let a: Gizmo? = nil\n", count: 40)
        let calls = String(repeating: "    _ = Gizmo()\n", count: 5)
        let literals = String(repeating: "    let s = \"Gizmo()\"\n", count: 4)
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": NoStoreSweepTests.gizmo,
            "\(NoStoreSweepTests.shelf)/Kiosk.swift": "struct Kiosk {\n" + annotated + calls + literals + "}\n",
            "\(NoStoreSweepTests.shelf)/Shop.swift": "struct Shop {\n" + String(repeating: "        _ = Gizmo()\n", count: 60) + "}\n",
        ], to: root)

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn 'Gizmo()' Sources", in: root))

        #expect(answered.reason.contains("35 more sites past the per-file cap and 4 other lines no site accounts for"), "\(answered.reason)")
    }

    /// The note names each count under its own words.
    @Test
    func theNoteNamesSitesPastTheCapApartFromLinesNoSiteAccountsFor() {
        #expect(UnshownGrepLines(comments: 0, others: 1, cut: 30).note(under: ["Sources"]) == "30 more sites past the per-file cap and 1 other line no site accounts for under Sources also match, not shown here — re-run the identical command to see them")
    }
}
