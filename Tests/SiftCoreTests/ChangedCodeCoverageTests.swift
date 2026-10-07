//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `run --coverage`'s section: line counts read from an `llvm-cov export` the way `llvm-cov` reads them, per changed declaration, and refused where the profile is not this tree's.
@Suite(.temporaryDirectories)
struct ChangedCodeCoverageTests {
    /// An export in `llvm-cov`'s own shape: one function at lines 3–9 whose middle never ran, with the fields a real export carries beside the segments.
    private static let export = Data("""
    {"data":[{"files":[{"branches":[],"filename":"/repo/Sources/Kit/Greeter.swift","mcdc_records":[],\
    "segments":[[3,20,1,true,true,false],[5,12,0,true,true,false],[7,10,1,true,false,false],[9,2,0,false,false,false]],\
    "summary":{"lines":{"count":7,"covered":5}}}],"totals":{}}],"type":"llvm.coverage.json.export","version":"3.0.1"}
    """.utf8)

    @Test func linesAreCountedAsLlvmCovCountsThem() throws {
        let counts = try CoverageAnswer.lineCounts(fromExport: Self.export)["/repo/Sources/Kit/Greeter.swift"]

        #expect(counts == [3: 1, 4: 1, 5: 1, 6: 0, 7: 0, 8: 1, 9: 1])
    }

    @Test func eachChangedDeclarationNamesItsUncoveredRangeAndTheChangeGetsOneTotal() throws {
        let counts = try CoverageAnswer.lineCounts(fromExport: Self.export)["/repo/Sources/Kit/Greeter.swift"]
        let declarations = [
            ChangedDeclaration(path: "Sources/Kit/Greeter.swift", label: "Greeter.name", lines: [1 ... 1]),
            ChangedDeclaration(path: "Sources/Kit/Greeter.swift", label: "Greeter.greet(_:)", lines: [3 ... 9]),
            ChangedDeclaration(path: "Sources/Kit/Unbuilt.swift", label: "helper()", lines: [2 ... 4]),
        ]
        let lines = CoverageAnswer.render(declarations, counts: ["Sources/Kit/Greeter.swift": counts ?? [:]], change: "the working tree against HEAD")

        #expect(lines == [
            "coverage: 3 changed declarations — the working tree against HEAD",
            "  Sources/Kit/Greeter.swift",
            "    Greeter.name :1 — no code to run",
            "    Greeter.greet(_:) :3-9 — 5 of 7 lines ran; not run :6-7",
            "  Sources/Kit/Unbuilt.swift — not measured: no test bundle this run built compiles it",
            "    helper() :2-4 — not measured",
            "coverage total: 5 of 7 lines ran in the changed declarations (71%)",
        ])
    }

    /// A file's export with the given segments, in `llvm-cov`'s shape.
    private static func export(_ segments: String) -> Data {
        Data("""
        {"data":[{"files":[{"filename":"/repo/F.swift","segments":[\(segments)]}]}],"type":"llvm.coverage.json.export","version":"3.0.1"}
        """.utf8)
    }

    @Test func aGapRegionCarriesTheCountAroundItAndIsNotALineOfCodeOfItsOwn() throws {
        let data = Self.export("[1,0,5,true,true,false],[2,4,7,true,true,true],[3,0,0,false,false,false]")

        #expect(try CoverageAnswer.lineCounts(fromExport: data)["/repo/F.swift"] == [1: 5, 2: 5, 3: 7])
    }

    @Test func aSkippedRegionIsNotCodeAndTheLinesItOpensOnAreLeftOut() throws {
        let data = Self.export("[1,0,4,true,true,false],[2,0,0,false,true,false],[3,0,9,true,true,false],[4,0,0,false,false,false]")

        #expect(try CoverageAnswer.lineCounts(fromExport: data)["/repo/F.swift"] == [1: 4, 3: 9, 4: 9])
    }

    @Test func onlyTheBundlesThePackageDeclaresAreReadAndAStaleOneBesideThemIsNever() throws {
        let present = ["AlphaTests.xctest", "BackorderTests.xctest", "BetaTests.xctest", "notes.txt"]

        #expect(try CoverageObjects.select(declared: ["BackorderTests", "BetaTests"], present: present) == ["BackorderTests.xctest", "BetaTests.xctest"])
        let missing = #expect(throws: CoverageObjectsRefusal.self) {
            try CoverageObjects.select(declared: ["BackorderTests", "ChartGridTests"], present: present)
        }
        #expect(missing?.reason.contains("ChartGridTests.xctest") == true)
        #expect(throws: CoverageObjectsRefusal.self) { try CoverageObjects.select(declared: nil, present: present) }
    }

    @Test func aChangedFileWithNoExecutableCodeStillListsEveryDeclarationAsHavingNoCodeToRun() {
        let declarations = [
            ChangedDeclaration(path: "Sources/Kit/P.swift", label: "Q", lines: [1 ... 1]),
            ChangedDeclaration(path: "Sources/Kit/P.swift", label: "T", lines: [2 ... 2]),
            ChangedDeclaration(path: "Package.swift", label: "package", lines: [3 ... 5]),
        ]
        let root = URL(fileURLWithPath: "/repo")
        let measured = ["/repo/Sources/Kit/A.swift"]
        #expect(CoverageAnswer.isCompiledBeside("Sources/Kit/P.swift", root: root, measured: measured))
        #expect(!CoverageAnswer.isCompiledBeside("Package.swift", root: root, measured: measured))

        let lines = CoverageAnswer.render(declarations, counts: ["Sources/Kit/P.swift": [:]], change: "the working tree against HEAD")

        #expect(lines == [
            "coverage: 3 changed declarations — the working tree against HEAD",
            "  Package.swift — not measured: no test bundle this run built compiles it",
            "    package :3-5 — not measured",
            "  Sources/Kit/P.swift",
            "    Q :1 — no code to run",
            "    T :2 — no code to run",
            "coverage total: 0 of 0 lines ran in the changed declarations",
        ])
    }

    @Test func aWorkingTreeChangeNamesEachChangedDeclarationOnceIncludingAnUntrackedFile() throws {
        let root = try TestSources.makeTempRepo()
        let sources = root.appendingPathComponent("Sources/Kit")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let shape = sources.appendingPathComponent("Shape.swift")
        try "struct Shape {\n    var name = \"x\"\n    func area() -> Int {\n        1\n    }\n}\n".write(to: shape, atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "shape"], in: root)
        try "struct Shape: Sendable {\n    var name = \"x\"\n    func area() -> Int {\n        2\n    }\n}\n".write(to: shape, atomically: true, encoding: .utf8)
        try "func fresh() {\n    run()\n}\n".write(to: sources.appendingPathComponent("Fresh.swift"), atomically: true, encoding: .utf8)

        let found = try ChangedDeclaration.inWorkingTree(against: "HEAD", git: GitContext(repoRoot: root))

        #expect(found.map { "\($0.path) \($0.label) \($0.lines.map(\.lowerBound)) to \($0.lines.map(\.upperBound))" } == [
            "Sources/Kit/Fresh.swift fresh() [1] to [3]",
            "Sources/Kit/Shape.swift Shape [1, 6] to [1, 6]",
            "Sources/Kit/Shape.swift Shape.area() [3] to [5]",
        ])
    }

    @Test func aProfileFromAnotherTreeOrAnEarlierBuildIsRefused() {
        let started = Date(timeIntervalSince1970: 1000)
        let tree = TreeKey(value: "aaaaaaaaaaaaaaaa")
        #expect(CoverageAnswer.refusal(treeBefore: tree, treeAfter: tree, profileWritten: started.addingTimeInterval(5), runStarted: started) == nil)
        let moved = CoverageAnswer.refusal(treeBefore: tree, treeAfter: TreeKey(value: "bbbbbbbbbbbbbbbb"), profileWritten: started.addingTimeInterval(5), runStarted: started)
        #expect(moved?.contains("the tree changed while the tests ran") == true)
        let earlier = CoverageAnswer.refusal(treeBefore: tree, treeAfter: tree, profileWritten: started.addingTimeInterval(-5), runStarted: started)
        #expect(earlier?.contains("predates this run") == true)
        #expect(CoverageAnswer.refusal(treeBefore: nil, treeAfter: tree, profileWritten: started, runStarted: started) != nil)
        #expect(CoverageAnswer.refused("x") == ["coverage: refused — x"])
    }
}
