//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A sweep of a tree with no index store is answered in place with the syntactic `where`, which lists every use by written name: a line it shows accounts for the grep line, and a line it does not show still fails the proof.
@Suite(.temporaryDirectories)
struct NoStoreSweepTests {
    /// The type every search here is for, declared in one file and used on two lines of another.
    static var gizmo: String {
        "struct Gizmo {\n    var size = 1\n}\n"
    }

    /// The directory the uses sit in, deep enough that each line a grep prints there, its path first, outweighs the row an answer lists that line by: a sweep is answered only where its answer is the smaller.
    static var shelf: String {
        "Sources/App/Stock/Aisles/Bays/Racks/Shelves/Bins/Trays/Slots/Rows/Columns"
    }

    /// A shop using `name` on its two properties, lines 2 and 3, and on each of `stocked` lines of a function after them, line 5 on.
    static func shop(using name: String = "Gizmo", stocked: Int = 24) -> String {
        "struct Shop {\n    let first = \(name)()\n    let second: \(name)? = nil\n    func stock() {\n"
            + String(repeating: "        _ = \(name)()\n", count: stocked) + "    }\n}\n"
    }

    /// A repository no build has indexed, holding ``gizmo`` and a ``shop(using:stocked:)`` under ``shelf``, with `extra` appended to the shop; `small` keeps the shop to its two properties, under `Sources/App`.
    static func unbuiltRepository(shopTail extra: String = "", small: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": gizmo,
            small ? "Sources/App/Shop.swift" : "\(shelf)/Shop.swift": shop(stocked: small ? 0 : 24) + extra,
        ], to: root)
        #expect(!ReadOnlyIndex.hasIndexStore(atRoot: root.path), sourceLocation: sourceLocation)
        return root
    }

    /// An anchored sweep whose every printed line is a code use is answered with `where --refs`, every one of those lines shown in the answer, and the answer says it matched by written name.
    @Test
    func anAnchoredSweepWithNoStoreIsAnsweredWithEveryLineItPrints() async throws {
        let root = try Self.unbuiltRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gizmo Sources", in: root))
        let lines = answered.reason.split(separator: "\n").map(String.init)

        #expect(lines.first?.contains("`where Gizmo (refs: true)`") == true)
        #expect(lines.contains { $0.hasPrefix("no store for uses; sites by written name") })
        // The lines the grep prints: the declaration, and the twenty-six uses in the shop.
        #expect(lines.contains { $0.hasSuffix("Sources/App/Gizmo.swift:1-3") })
        #expect(lines.contains("  \(Self.shelf)/Shop.swift (26):"))
        #expect(lines.contains("    :2  | let first = Gizmo()"))
        #expect(lines.contains("    :3  | let second: Gizmo? = nil"))
        #expect(lines.contains { $0.hasPrefix("    :28 ") })
    }

    /// A sweep with no store whose answer is no smaller than what its grep prints is withheld on worth, as one with a store is: the size rule makes no exception for the syntactic answer, and the grep runs.
    @Test
    func aSweepWithNoStoreNoSmallerThanItsGrepIsNotSmaller() async throws {
        let root = try Self.unbuiltRepository(small: true)

        for command in ["grep -rnw Gizmo Sources", "grep -rn Gizmo Sources"] {
            #expect(try await InPlaceAnswerTests.outcome(command, in: root) == .withheld(.notSmaller), "\(command)")
        }
    }

    /// A function's calls are listed one row per line under their file, a line calling it twice folded to one row with its count, and each such row accounts for the line the grep prints.
    @Test
    func aSweepForAFunctionIsAnsweredWithTheRowsOfItsCalls() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let calls = String(repeating: "        restock()\n", count: 24)
        try MCPTestRepo.add([
            "\(Self.shelf)/Depot.swift": "struct Depot {\n    func restock() {}\n    func open() {\n        restock(); restock()\n\(calls)    }\n}\n",
        ], to: root)
        #expect(!ReadOnlyIndex.hasIndexStore(atRoot: root.path))

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw restock Sources", in: root))
        let lines = answered.reason.split(separator: "\n").map(String.init)

        #expect(lines.first?.contains("`where restock (refs: true)`") == true)
        #expect(lines.contains { $0.hasPrefix("    :4 (×2)") })
        #expect(lines.contains { $0.hasPrefix("    :5 ") })
    }

    /// A comment naming the name is a line the grep prints and no `where` shows, so the anchored proof fails and the loose reading stands in, the plain `where` that leaves comments out as it does with a store.
    @Test
    func aCommentLineFailsTheAnchoredProofAndTheLooseAnswerStands() async throws {
        let root = try Self.unbuiltRepository(shopTail: "// A Gizmo is cheap.\n")

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gizmo Sources", in: root))
        let lines = answered.reason.split(separator: "\n").map(String.init)

        #expect(lines.first?.contains("`where Gizmo`") == true)
        #expect(lines.contains { $0.hasPrefix("no store for uses; sites by written name") })
        #expect(!answered.reason.contains("A Gizmo is cheap"))
    }

    /// A loose name search with no store is answered with the syntactic `where`, and the answer as served says it is syntactic.
    @Test
    func aLooseNameSearchWithNoStoreIsAnsweredAndSaysItIsSyntactic() async throws {
        let root = try Self.unbuiltRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Gizmo Sources", in: root))
        let lines = answered.reason.split(separator: "\n").map(String.init)

        #expect(lines.first?.contains("`where Gizmo`") == true)
        #expect(lines.contains { $0.hasPrefix("no store for uses; sites by written name") })
        #expect(lines.contains { $0.hasPrefix("\"Gizmo\" (") && $0.contains("uses by written name") })
    }

    /// A repository no build has indexed, ``gizmo`` declared under `Sources/Kit`, used only by a ``shop(using:stocked:)`` under `Sources/App`, and a third directory naming it nowhere.
    static func splitRepository(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Sources/Kit/Gizmo.swift": gizmo,
            "\(shelf)/Shop.swift": shop(),
            "Sources/Spare/Spare.swift": "struct Spare {}\n",
        ], to: root)
        #expect(!ReadOnlyIndex.hasIndexStore(atRoot: root.path), sourceLocation: sourceLocation)
        return root
    }

    /// A search of a directory holding only uses of a name declared elsewhere is answered: with no store the answer resolves the declaration alone, but it shows each use inside the search by written name, and those lines are what the bound asks for.
    @Test
    func aSearchOfADirectoryHoldingOnlyUsesIsAnswered() async throws {
        let root = try Self.splitRepository()
        let tool = try #require(InPlaceShape.match(forSearchTool: "Grep", input: ["pattern": "Gizmo", "path": "Sources/App"], in: root.path))

        for command in ["grep -rn Gizmo Sources/App", "grep -rnw Gizmo Sources/App"] {
            let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))
            #expect(answered.calls.map(\.target) == ["Gizmo"], "\(command)")
            #expect(answered.reason.contains("    :2  | let first = Gizmo()"), "\(command)")
        }
        guard case .answered = try await InPlaceAnswerTests.answer(tool.call, from: tool.directory) else {
            Issue.record("the Grep form of the search was not answered")
            return
        }
    }

    /// A search of a directory holding no line naming the name is still withheld as outside the search: no row of the answer lies in it, and the search printing nothing is the truth.
    @Test
    func aSearchOfADirectoryNamingItNowhereIsOutsideTheSearch() async throws {
        let root = try Self.splitRepository()

        #expect(try await InPlaceAnswerTests.outcome("grep -rn Gizmo Sources/Spare", in: root) == .withheld(.outsideSearch))
    }
}
