//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two numbers one `affected` answer prints for the same tests, and the line a changed file that has since gone gets.
///
/// No build: the name-match fallback reaches these tests, which is all the counts need.
@Suite(.temporaryDirectories)
struct AffectedCountAgreementTests {
    private static func manifest() -> String {
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

    /// A repository with a `Widget` and the given test files, `Widget` changed and left uncommitted.
    private static func affected(testFiles: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for (name, source) in testFiles {
            try TestSources.write(source, to: "Tests/LibTests/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// A target's own count is the sum of what its rows stand for, so a whole XCTest case is its tests there as it is in the headline.
    @Test
    func aTargetsCountAgreesWithTheHeadlineForAWholeCase() async throws {
        let output = try await Self.affected(testFiles: [
            "LampTests": """
            import XCTest
            @testable import Lib

            final class LampTests: XCTestCase {
                let widget = Widget()
                func testOne() {}
                func testTwo() {}
                func testThree() {}
            }
            """,
        ])

        #expect(output.contains("affected tests (3 in 1 target):"))
        #expect(output.contains("  LibTests — 3 tests"))
    }

    /// A historical range names a file the working tree has since lost as gone, not as one that merely declares nothing.
    @Test
    func aFileRenamedSinceTheRangeIsNamedAsGoneFromTheWorkingTree() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Account {}\n", to: "Sources/Lib/Account.swift", in: root)
        try TestSources.commitAll(in: root, message: "first")
        try TestSources.write("public struct Account {\n    public var id = 1\n}\n", to: "Sources/Lib/Account.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Sources/Lib/Account.swift"), to: root.appendingPathComponent("Sources/Lib/Bank.swift"))
        try TestSources.commitAll(in: root, message: "rename")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.affected(
            options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~2", to: "HEAD~1")),
            freshness: freshness
        )

        let line = try #require(output.split(separator: "\n").first { $0.contains("Sources/Lib/Account.swift — ") })

        #expect(line.contains("no longer in the working tree"))
        #expect(!line.contains("no declarations in the index"))
    }
}
