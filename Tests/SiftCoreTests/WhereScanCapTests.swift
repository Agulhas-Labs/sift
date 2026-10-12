//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The lower-bound scans of `where` search every candidate file for the name's bytes and cap only the lexing of files that hold them, so a tree with many unrelated files neither misses a mention past the cap nor reports files as not scanned.
@Suite(.temporaryDirectories, .serialized)
struct WhereScanCapTests {
    /// More outside files than the scan cap, none writing the name, so there is nothing to qualify.
    private static func writeOutsideFiles(count: Int, in root: URL, mentioningLast: Bool = false) throws -> [String] {
        let paths = (0 ..< count).map { String(format: "Fixtures/Gizmo%04d.swift", $0) }
        for (index, path) in paths.enumerated() {
            let mentions = mentioningLast && index == count - 1
            try TestSources.write(mentions ? "let a = w.walk\n" : "let a = 0\n", to: path, in: root)
        }
        return paths
    }

    /// Past the old two-hundred-file cap with no file writing the name, the line is empty rather than reporting files as not scanned.
    @Test
    func manyOutsideFilesNoneMentioningTheNameLeaveNoNotScannedClause() throws {
        let root = try TestSources.makeTempDirectory()
        let paths = try Self.writeOutsideFiles(count: WhereUnbuiltMentions.scanCap + 25, in: root)

        let line = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path)

        #expect(line == nil, "\(line ?? "")")
    }

    /// The one file writing the name sits past position two hundred in path order and is still listed, with nothing counted as not scanned.
    @Test
    func aMentioningFilePastTheOldCapIsFound() throws {
        let root = try TestSources.makeTempDirectory()
        let paths = try Self.writeOutsideFiles(count: WhereUnbuiltMentions.scanCap + 25, in: root, mentioningLast: true)

        let line = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path)

        #expect(line == "not in the build, mention the name: \(paths[paths.count - 1]):1", "\(line ?? "")")
    }

    /// Files that hold the name past the lexing cap are the only ones counted as not scanned.
    @Test
    func onlyFilesHoldingTheNamePastTheLexingCapAreCounted() throws {
        let root = try TestSources.makeTempDirectory()
        var paths = try Self.writeOutsideFiles(count: 10, in: root)
        for name in ["Fixtures/Zeta.swift", "Fixtures/Zulu.swift"] {
            try TestSources.write("let a = w.walk\n", to: name, in: root)
            paths.append(name)
        }

        let line = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path, scanCap: 1)

        #expect(line == "not in the build, mention the name: Fixtures/Zeta.swift:1 · 1 outside file not scanned", "\(line ?? "")")
    }

    /// More new files than the changed-file scan cap, the only one writing the name last in path order, is still listed.
    @Test
    func aMentioningNewFilePastTheChangedScanCapIsFound() async throws {
        let root = try TestSources.makeTempRepo()
        #expect(try TemporaryDirectory.entries(containing: root.lastPathComponent) == [root.lastPathComponent])
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Lib\",\n    targets: [.target(name: \"Lib\")]\n)\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public func compute() -> Int {\n    1\n}\n", to: "Sources/Lib/Compute.swift", in: root)
        try TestSources.write("public func first() -> Int {\n    compute()\n}\n", to: "Sources/Lib/First.swift", in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        for index in 0 ..< WhereUnbuiltMentions.scanCap + 5 {
            try TestSources.write("public let gizmo\(index) = 0\n", to: String(format: "Sources/Lib/Gizmo%04d.swift", index), in: root)
        }
        try TestSources.write("public func added() -> Int {\n    compute()\n}\n", to: "Sources/Lib/Zeta.swift", in: root)

        let answer = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())

        #expect(answer.split(separator: "\n").contains("new since last build, not in the store, mention the name: Sources/Lib/Zeta.swift:2"), "\(answer)")
    }

    /// A buildable package of one target for the changed-file tests, built and indexed with `files` as committed.
    private static func builtEngine(files: [String: String], in root: URL) async throws -> SiftEngine {
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Lib\",\n    targets: [.target(name: \"Lib\")]\n)\n",
            to: "Package.swift",
            in: root
        )
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        return engine
    }

    /// With the changed-file count past the cap, exactly the files holding the name beyond the cap are counted as not scanned.
    @Test
    func theChangedFileCountPastTheCapIsTheFilesHoldingTheNameBeyondIt() async throws {
        let root = try TestSources.makeTempRepo()
        let engine = try await Self.builtEngine(
            files: [
                "Sources/Lib/Compute.swift": "public func compute() -> Int {\n    1\n}\n",
                "Sources/Lib/First.swift": "public func first() -> Int {\n    compute()\n}\n",
            ],
            in: root
        )
        for index in 0 ..< WhereUnbuiltMentions.scanCap + 3 {
            try TestSources.write("public func added\(index)() -> Int {\n    compute()\n}\n", to: String(format: "Sources/Lib/Added%04d.swift", index), in: root)
        }

        let answer = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())

        #expect(answer.contains("· 3 new or changed files not scanned"), "\(answer)")
    }

    /// Where the several-owners answer reads no stored file, changed files the store holds use up no lexing slot, so a new file after them is listed and nothing is counted as not scanned.
    @Test
    func storedChangedFilesUseNoSlotWhereStoredFilesAreNotRead() async throws {
        let root = try TestSources.makeTempRepo()
        var files = [
            "Sources/Lib/Types.swift": "struct Depot {\n    func load(_ value: Int) {}\n}\nstruct Orchard {\n    func load(_ value: Int) {}\n}\n",
        ]
        let stored = (0 ..< WhereUnbuiltMentions.scanCap + 5).map { String(format: "Sources/Lib/Call%04d.swift", $0) }
        for (index, path) in stored.enumerated() {
            files[path] = "func call\(index)(_ depot: Depot) {\n    depot.load(1)\n}\n"
        }
        let engine = try await Self.builtEngine(files: files, in: root)
        for path in stored {
            try TestSources.write(files[path, default: ""] + "// edited\n", to: path, in: root)
        }
        try TestSources.write("func added(_ depot: Depot) {\n    depot.load(2)\n}\n", to: "Sources/Lib/Zeta.swift", in: root)

        let answer = try await engine.lookup(symbol: "load", freshness: engine.ensureFresh())

        #expect(answer.contains("Sources/Lib/Zeta.swift:2"), "\(answer)")
        #expect(!answer.contains("not scanned"), "\(answer)")
    }
}
