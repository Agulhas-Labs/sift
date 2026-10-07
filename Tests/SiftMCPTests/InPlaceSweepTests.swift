//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A word-anchored sweep answered in place with `where` and every reference site, on a package built with an index store: answered where every line the sweep prints is a declaration or a reference the answer lists.
///
/// Where one is a comment, a string or a use of another symbol of the name, the proof fails and the sweep falls back to the plain `where` the loose spelling of the same search is given; a cut across files leaves the search undecided, and that is refused.
@Suite(.temporaryDirectories)
struct InPlaceSweepTests {
    /// A package whose `Gadget` is declared in one file and referenced in another, built with an index store and indexed.
    private static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gadget.swift": "public struct Gadget {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var gadget: Gadget\n    func make() -> Gadget { Gadget() }\n    func take(_ part: Gadget) {}\n}\n",
            "Sources/App/Widget.swift": "struct Widget {}\n// Widget in a comment\nlet label = \"Widget in a string\"\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    @Test
    func aSweepIsAnsweredOnlyWhereTheReferencesAccountForEveryLine() async throws {
        let root = try await Self.builtPackage()

        // The declaration and every reference, a type annotation and a parameter's type among them.
        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rnw Gadget Sources", in: root))

        #expect(answered.calls.map(\.tool) == ["where"])
        #expect(answered.reason.hasPrefix("sift answered this with `where Gadget (refs: true)` instead of running it"))
        #expect(answered.reason.contains("Sources/App/Uses.swift (3):\n    :2  | var gadget: Gadget\n    :3  | func make() -> Gadget { Gadget() }\n    :4  | func take(_ part: Gadget) {}"))
        #expect(try await InPlaceAnswerTests.answered(#"grep -rn '\<Gadget\>' Sources --include=*.swift"#, in: root) != nil)

        // A comment and a string literal are lines the store never records, so the proof fails — and the sweep is
        // then answered as the loose spelling of it is, with the plain `where` and no reference sites claimed.
        let widget = try #require(try await InPlaceAnswerTests.answered("grep -rnw Widget Sources", in: root))
        #expect(widget.reason.hasPrefix("sift answered this with `where Widget` instead of running it"))
        // Case-folded, the sweep for `gadget` prints the type's lines too, which `where gadget` does not list, so
        // the proof fails there as well — and it does not fall back, since `where` resolves the name as written
        // and the search does not, so the loose answer would not say what the search says.
        #expect(try await InPlaceAnswerTests.outcome("grep -rniw gadget Sources", in: root) == .withheld(.notExact))
        // A cut across files keeps lines in an order grep does not fix.
        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Sources | head -2", in: root) == .withheld(.unchecked))
    }

    /// A sweep's search stops, and nothing opens the engine for it, at the first line of a file no `where` answer lists lines of, or once the lines it prints could not all be located inside the size budget.
    ///
    /// Past the budget that refusal is the answer; where the proof merely failed, what opens the engine afterwards is the fallback to the names shape, on its own account.
    @Test
    func aSweepNoAnswerCouldHoldIsRefusedFromItsSearchAlone() async throws {
        let root = try await Self.builtPackage()
        let docs = root.appendingPathComponent("Docs")
        let generated = root.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try "Gadget is documented here\n".write(to: docs.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        // More lines than any answer inside the budget could number, in a file the index has not seen yet.
        try (1 ... 2500).map { "let gadget\($0) = Gadget()" }.joined(separator: "\n")
            .write(to: generated.appendingPathComponent("Many.swift"), atomically: true, encoding: .utf8)
        let before = try #require(ReadOnlyIndex.snapshot(atRoot: root.path)).files

        #expect(try await InPlaceAnswerTests.outcome("grep -rnw Gadget Generated", in: root) == .withheld(.overSize))
        #expect(ReadOnlyIndex.snapshot(atRoot: root.path)?.files == before)
        // The prose file stops the search the same way, and the proof having failed there, the sweep is asked again
        // as the names shape — which opens the engine, and is withheld because `Docs` holds none of the sites it
        // locates. So the cheap refusal is still what the search alone buys; what follows it is the fallback's.
        let docsSweep = try await InPlaceAnswerTests.outcome("grep -rnw Gadget Docs", in: root)
        #expect(docsSweep == .withheld(.outsideSearch))
    }

    /// `-x` restricts a search to whole-line matches, which a declaration site's line almost never is, so a sweep combined with it is never answered — not even where `Gadget` is a real, indexed name a word-anchored sweep for it alone would resolve.
    @Test
    func aWholeLineSweepIsNeverAnsweredEvenWhereItsNameIsReal() async throws {
        let root = try await Self.builtPackage()

        #expect(InPlaceShape.match(forShell: "grep -rnwx Gadget Sources", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -rn -w -x Gadget Sources", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: "grep -rnw --line-regexp Gadget Sources", in: root.path) == nil)
        #expect(InPlaceShape.match(forShell: #"grep -rnx '\<Gadget\>' Sources"#, in: root.path) == nil)
    }
}
