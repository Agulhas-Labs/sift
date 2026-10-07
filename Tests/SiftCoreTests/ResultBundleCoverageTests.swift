//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `run --coverage -- xcodebuild test`: line counts read from what `xccov view --archive` prints, and a result bundle refused where it is not this run's of this tree.
@Suite(.temporaryDirectories)
struct ResultBundleCoverageTests {
    /// `xccov view --archive --file <path> --json` in its own shape, captured from a real result bundle and cut down: a line with no code, lines that ran, one with a partly run subrange, and one that never ran.
    private static let file = Data("""
    {"\\/repo\\/Sources\\/Kit\\/Greeter.swift":[{"isExecutable":false,"line":1},{"isExecutable":false,"line":2},\
    {"executionCount":8,"isExecutable":true,"line":3},{"executionCount":8,"isExecutable":true,"line":4,\
    "subranges":[{"column":9,"executionCount":0,"length":26}]},{"executionCount":0,"isExecutable":true,"line":5},\
    {"executionCount":51909,"isExecutable":true,"line":6},{"isExecutable":false,"line":7}]}
    """.utf8)

    @Test func executableLinesCarryTheirCountsAndTheRestAreNotCode() throws {
        let counts = try ResultBundleCoverage.lineCounts(fromFile: Self.file)

        #expect(counts == ["/repo/Sources/Kit/Greeter.swift": [3: 8, 4: 8, 5: 0, 6: 51909]])
    }

    @Test func theFileListIsReadAsAbsolutePaths() throws {
        let list = Data(#"["\/repo\/Sources\/Kit\/Greeter.swift","\/repo\/Tests\/Kit\/Checks.swift"]"#.utf8)

        #expect(try ResultBundleCoverage.files(fromFileList: list) == ["/repo/Sources/Kit/Greeter.swift", "/repo/Tests/Kit/Checks.swift"])
        #expect(throws: CoverageObjectsRefusal.self) { try ResultBundleCoverage.files(fromFileList: Data(#"{"a":1}"#.utf8)) }
        #expect(throws: CoverageObjectsRefusal.self) { try ResultBundleCoverage.lineCounts(fromFile: Data("[]".utf8)) }
    }

    @Test func theCountsRenderAsTheChangedDeclarationsLines() throws {
        let counts = try ResultBundleCoverage.lineCounts(fromFile: Self.file)["/repo/Sources/Kit/Greeter.swift"] ?? [:]
        let declarations = [ChangedDeclaration(path: "Sources/Kit/Greeter.swift", label: "Greeter.greet()", lines: [3 ... 6])]

        #expect(CoverageAnswer.render(declarations, counts: ["Sources/Kit/Greeter.swift": counts], change: "the working tree against HEAD") == [
            "coverage: 1 changed declaration — the working tree against HEAD",
            "  Sources/Kit/Greeter.swift",
            "    Greeter.greet() :3-6 — 3 of 4 lines ran; not run :5",
            "coverage total: 3 of 4 lines ran in the changed declarations (75%)",
        ])
    }

    /// A result bundle whose `Info.plist` was written at `written`.
    private static func bundle(written: Date) throws -> URL {
        let bundle = try TemporaryDirectory.make("result").appendingPathComponent("run.xcresult")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info = bundle.appendingPathComponent("Info.plist")
        try Data("<plist/>".utf8).write(to: info)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: info.path)
        return bundle
    }

    @Test func aBundleThisRunWroteForThisTreeIsRead() throws {
        let started = Date(timeIntervalSinceNow: -60)
        let tree = TreeKey(value: "aaaaaaaaaaaaaaaa")

        #expect(try ResultBundleCoverage.refusal(bundle: Self.bundle(written: Date()), treeBefore: tree, treeAfter: tree, runStarted: started) == nil)
    }

    @Test func aBundleOlderThanTheRunIsRefused() throws {
        let started = Date()
        let tree = TreeKey(value: "aaaaaaaaaaaaaaaa")

        let refusal = try ResultBundleCoverage.refusal(bundle: Self.bundle(written: started.addingTimeInterval(-3600)), treeBefore: tree, treeAfter: tree, runStarted: started)

        #expect(refusal?.contains("predates this run") == true)
    }

    @Test func aBundleFromATreeThatMovedDuringTheRunIsRefused() throws {
        let refusal = try ResultBundleCoverage.refusal(
            bundle: Self.bundle(written: Date()),
            treeBefore: TreeKey(value: "aaaaaaaaaaaaaaaa"),
            treeAfter: TreeKey(value: "bbbbbbbbbbbbbbbb"),
            runStarted: Date(timeIntervalSinceNow: -60)
        )

        #expect(refusal?.contains("the tree changed while the tests ran") == true)
    }

    @Test func aRunThatLeftNoBundleIsRefused() throws {
        let missing = try TemporaryDirectory.make("result").appendingPathComponent("none.xcresult")
        let tree = TreeKey(value: "aaaaaaaaaaaaaaaa")

        let refusal = ResultBundleCoverage.refusal(bundle: missing, treeBefore: tree, treeAfter: tree, runStarted: Date())

        #expect(refusal?.contains("left no result bundle") == true)
    }
}
