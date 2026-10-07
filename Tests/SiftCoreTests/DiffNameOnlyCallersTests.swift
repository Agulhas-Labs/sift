//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift diff` lists a changed function's callers as `where` does: a name written with no call is counted after an empty list, and a reference the store records with no call is marked as one.
@Suite(.temporaryDirectories)
struct DiffNameOnlyCallersTests {
    /// With no site listed, "0 call sites" of a function reached only as `x.f` reads as unused, so the diff says where the name is still written, in `where`'s words.
    @Test
    func aChangedFunctionReachedOnlyByNameSaysWhereTheNameIsWritten() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(DiffEngineTests.manifest(), to: "Package.swift", in: root)
        try TestSources.write(Self.lonely(returning: "Int", value: "1"), to: "Sources/Lib/Lonely.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(Self.lonely(returning: "String", value: "\"1\""), to: "Sources/Lib/Lonely.swift", in: root)

        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("~ Lonely.only() — name-matched on \"only\""), "\(output)")
        #expect(output.contains("      but the name is written once with no call"), "\(output)")
        #expect(output.contains("        Sources/Lib/Lonely.swift:5  in pick(_:)"), "\(output)")
    }

    /// A reference the store records with no call is marked in the diff's list as in `where`'s, so a function handed on unapplied is not read as called.
    @Test
    func aStoreReferenceWithNoCallIsMarkedInTheDiff() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.depot(returning: "String?", body: "command.isEmpty ? nil : command"), to: "Sources/GizmoCore/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "before")
        try TestSources.write(Self.depot(returning: "String", body: "command"), to: "Sources/GizmoCore/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "a non-optional result")
        try TestSources.swiftBuild(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let range = try DiffRange.resolve("HEAD", git: GitContext(repoRoot: root))
        let output = try await engine.diff(options: DiffOptions(range: range, member: nil, offset: 0), freshness: freshness)

        #expect(output.contains("resolved by the index store: 2 call sites"), "\(output)")
        #expect(output.contains("      moves(_:) — Sources/GizmoCore/Depot.swift:7 — referenced, not called"), "\(output)")
        #expect(output.split(separator: "\n").contains("      direct() — Sources/GizmoCore/Depot.swift:11"), "\(output)")
    }

    /// A name-only block caps at `diff`'s own limit, not `where`'s wider one, and points at `sift where` for the rest exactly as the resolved site list does.
    @Test
    func aNameOnlyBlockCapsAtDiffsOwnLimit() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(DiffEngineTests.manifest(), to: "Package.swift", in: root)
        try TestSources.write(Self.manyPickers(returning: "Int", value: "1", count: 10), to: "Sources/Lib/Lonely.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(Self.manyPickers(returning: "String", value: "\"1\"", count: 10), to: "Sources/Lib/Lonely.swift", in: root)

        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("~ Lonely.only() — name-matched on \"only\""), "\(output)")
        for index in 0 ..< 8 {
            #expect(output.contains("        Sources/Lib/Lonely.swift:\(index + 4)  in pick\(index)(_:)"), "\(output)")
        }
        #expect(!output.contains("Sources/Lib/Lonely.swift:12  in pick8(_:)"), "\(output)")
        #expect(!output.contains("Sources/Lib/Lonely.swift:13  in pick9(_:)"), "\(output)")
        #expect(output.contains("        truncated: 2 more — `sift where Lonely.only()` lists them all"), "\(output)")
    }

    static func manyPickers(returning type: String, value: String, count: Int) -> String {
        var lines = [
            "struct Lonely {",
            "    func only() -> \(type) { \(value) }",
            "}",
        ]
        for index in 0 ..< count {
            lines.append("func pick\(index)(_ l: Lonely) -> () -> \(type) { l.only }")
        }
        return lines.joined(separator: "\n")
    }

    static func lonely(returning type: String, value: String) -> String {
        """
        struct Lonely {
            func only() -> \(type) { \(value) }
        }
        func pick(_ l: Lonely) -> () -> \(type) {
            return l.only
        }
        """
    }

    static func depot(returning type: String, body: String) -> String {
        """
        enum Depot {
            static func restock(from command: String) -> \(type) {
                \(body)
            }

            static func moves(_ commands: [String]) -> [\(type)] {
                commands.map(restock(from:))
            }

            static func direct() -> \(type) {
                restock(from: "north")
            }
        }
        """
    }
}
