//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `diff --coverage`: the coverage a run recorded is shown for the tree it measured and for no other, and the record is one file replaced, never appended to.
@Suite(.temporaryDirectories)
struct CoverageRecordTests {
    /// A repository with `Sources/Kit/Shape.swift` committed and then changed in the working tree, and the key of the tree as it now stands.
    private static func changedRepository(sourceLocation: SourceLocation = #_sourceLocation) throws -> (root: URL, tree: TreeKey) {
        let root = try TestSources.makeTempRepo()
        let sources = root.appendingPathComponent("Sources/Kit")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let shape = sources.appendingPathComponent("Shape.swift")
        try "struct Shape {\n    func area() -> Int {\n        1\n    }\n}\n".write(to: shape, atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: root)
        try TestSources.runGit(["commit", "-m", "shape"], in: root)
        try "struct Shape {\n    func area() -> Int {\n        let side = 2\n        return side * side\n    }\n}\n".write(to: shape, atomically: true, encoding: .utf8)
        let tree = try #require(TreeKey.of(repositoryRoot: root), sourceLocation: sourceLocation)
        return (root, tree)
    }

    private static func record(for tree: TreeKey) -> CoverageRecord {
        CoverageRecord(tree: tree.value, command: ["swift", "test", "--enable-code-coverage"], measured: ["Sources/Kit/Shape.swift": [2: 3, 3: 3, 4: 0, 5: 3]], unmeasured: [])
    }

    @Test func theRecordedNumbersAreShownForTheTreeTheRunMeasured() throws {
        let (root, tree) = try Self.changedRepository()
        try Self.record(for: tree).write(in: root)

        #expect(CoverageRecord.section(in: root, tree: TreeKey.of(repositoryRoot: root)) == [
            "coverage: 1 changed declaration — the working tree against HEAD, as `swift test --enable-code-coverage` measured it",
            "  Sources/Kit/Shape.swift",
            "    Shape.area() :2-5 — 3 of 4 lines ran; not run :4",
            "coverage total: 3 of 4 lines ran in the changed declarations (75%)",
        ])
    }

    @Test func oneMoreEditMakesTheRecordStaleAndNoNumberIsShown() throws {
        let (root, tree) = try Self.changedRepository()
        try Self.record(for: tree).write(in: root)
        try "struct Shape {\n    func area() -> Int {\n        4\n    }\n}\n".write(to: root.appendingPathComponent("Sources/Kit/Shape.swift"), atomically: true, encoding: .utf8)

        let section = CoverageRecord.section(in: root, tree: TreeKey.of(repositoryRoot: root))

        #expect(section.count == 1)
        #expect(section.first?.hasPrefix("coverage: stale — `swift test --enable-code-coverage` measured tree \(tree.displayValue)") == true)
        #expect(section.first?.contains("lines ran") == false)
    }

    @Test func aChangedFileTheRecordNeverLookedAtMakesItStale() throws {
        let (root, tree) = try Self.changedRepository()
        try CoverageRecord(tree: tree.value, command: ["swift", "test"], measured: [:], unmeasured: []).write(in: root)

        let section = CoverageRecord.section(in: root, tree: tree)

        #expect(section == ["coverage: stale — `swift test` measured a change from another revision, which left out Sources/Kit/Shape.swift"])
    }

    @Test func aRepositoryNoRunMeasuredSaysSoAndATreeWithNoKeyIsRefused() throws {
        let (root, tree) = try Self.changedRepository()

        #expect(CoverageRecord.section(in: root, tree: tree).first?.hasPrefix("coverage: none recorded") == true)
        try Self.record(for: tree).write(in: root)
        #expect(CoverageRecord.section(in: root, tree: nil).first?.hasPrefix("coverage: refused — ") == true)
    }

    @Test func aLaterRunReplacesTheRecord() throws {
        let (root, tree) = try Self.changedRepository()
        try Self.record(for: TreeKey(value: "aaaaaaaaaaaaaaaa")).write(in: root)
        let later = Self.record(for: tree)
        try later.write(in: root)

        #expect(CoverageRecord.read(in: root) == later)
        #expect(try FileManager.default.contentsOfDirectory(atPath: SiftPaths.cache(in: root).path).filter { $0.hasPrefix("coverage") } == ["coverage.json"])
    }

    @Test func aRecordOlderThanTheWindowReadsStaleAndNamesItsAge() throws {
        let (root, tree) = try Self.changedRepository()
        let measured = Date()
        try Self.record(for: tree).write(in: root)

        let fresh = CoverageRecord.section(in: root, tree: tree, now: measured.addingTimeInterval(RunLedger.trustWindow - 60))
        let late = CoverageRecord.section(in: root, tree: tree, now: measured.addingTimeInterval(2 * RunLedger.trustWindow))

        #expect(fresh.first?.hasPrefix("coverage: 1 changed declaration") == true)
        #expect(late.count == 1)
        #expect(late.first?.contains("stale") == true)
        #expect(late.first?.contains("measured this tree 2h ago") == true)
    }

    @Test func aRecordWithoutATimeReadsStale() throws {
        let (root, tree) = try Self.changedRepository()
        try CoverageRecord(tree: tree.value, command: ["swift", "test"], measured: ["Sources/Kit/Shape.swift": [2: 1]], unmeasured: [], measuredAt: nil).write(in: root)

        let section = CoverageRecord.section(in: root, tree: tree)

        #expect(section.count == 1)
        #expect(section.first?.hasPrefix("coverage: stale — `swift test` recorded no time") == true)
    }
}
