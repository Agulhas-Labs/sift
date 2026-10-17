//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which outside-declaration changes still send an edited file to the whole-file seed: a comment changes no behaviour, so it does not.
@Suite(.serialized, .temporaryDirectories)
struct AffectedAfterEditCommentTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    private static var built: String {
        """
        import Foundation

        // The first note.
        func alpha() -> Int { 1 }

        func beta() -> Int { 2 }
        """
    }

    private static let suites: [(name: String, body: String)] = [
        ("AlphaTests", "@Test func one() { #expect(alpha() == 1) }"),
        ("BetaTests", "@Test func two() { #expect(beta() == 2) }"),
    ]

    private static func affectedAfterEditing(replacing edit: (from: String, to: String)) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write(built + "\n", to: "Sources/Lib/Lib.swift", in: root)
        for suite in suites {
            try TestSources.write("import Foundation\nimport Testing\n@testable import Lib\n\nstruct \(suite.name) {\n    \(suite.body)\n}\n", to: "Tests/LibTests/\(suite.name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        try TestSources.write(built.replacingOccurrences(of: edit.from, with: edit.to) + "\n", to: "Sources/Lib/Lib.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// A body edit beside a comment edit outside every declaration seeds the file from the edited function alone.
    @Test
    func aCommentOutsideEveryDeclarationLeavesTheFileSeededFromItsEditedFunction() async throws {
        let output = try await Self.affectedAfterEditing(replacing: ("// The first note.\nfunc alpha() -> Int { 1 }", "// A reworded note.\nfunc alpha() -> Int { 3 }"))

        #expect(output.contains("after-edit walk — syntactic"))
        #expect(output.contains("LibTests.AlphaTests/one()"))
        #expect(!output.contains("BetaTests"))
        #expect(!output.contains("seeded whole"))
    }

    /// A changed import is text outside every declaration that is not a comment, so the file is seeded whole and named with its reason.
    @Test
    func anImportChangedOutsideEveryDeclarationSeedsTheFileWholeAndSaysWhy() async throws {
        let output = try await Self.affectedAfterEditing(replacing: ("import Foundation\n", "import Foundation\nimport Dispatch\n"))

        #expect(output.contains("after-edit walk — seeded whole: text outside its declarations changed: Sources/Lib/Lib.swift"))
    }

    /// A file whose only change is a comment is accounted for with no seeds: it is not seeded whole and no test of it is listed.
    @Test
    func aFileWhoseOnlyChangeIsACommentIsWalkedFromNothingAndSaysSo() async throws {
        let output = try await Self.affectedAfterEditing(replacing: ("// The first note.", "// A reworded note."))

        #expect(output.contains("after-edit walk — only comments changed, so nothing was walked from: Sources/Lib/Lib.swift"))
        #expect(!output.contains("seeded whole"))
        #expect(!output.contains("AlphaTests"))
        #expect(!output.contains("BetaTests"))
    }
}
