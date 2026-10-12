//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Working-tree `affected` judges each changed file against its own build as a committed range does: a file edited since its unit and a file no unit holds are counted by kind and refused, and a file no build compiles stays not built.
@Suite(.serialized, .temporaryDirectories)
struct AffectedWorkingTreeJudgeTests {
    /// An uncommitted edit to a built file and an uncommitted new file in a built target are counted by kind in the header, refused, and handed to the after-edit walk.
    @Test
    func anEditedAndANewFileAreRefusedByKind() async throws {
        let root = try await Self.editedPackage()

        let output = try await Self.affected(root)

        #expect(output.contains("semantic: stale since last build (2 files: 1 changed, 1 new)"), "\(output)")
        #expect(output.contains("Sources/Beta/Other.swift was changed since the last build"), "\(output)")
        #expect(output.contains("Sources/Beta/Gizmo.swift is new since the last build"), "\(output)")
        #expect(output.contains("answered by the after-edit walk"), "\(output)")
    }

    /// The same edits committed and asked about as a range reach the same semantic verdict as the working tree did before the commit.
    @Test
    func theCommittedRangeReachesTheSameVerdict() async throws {
        let root = try await Self.editedPackage()
        let workingTree = try await Self.affected(root)
        try TestSources.commitAll(in: root, message: "edits")

        let range = try await Self.affected(root, range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD"))

        #expect(Self.semanticField(of: workingTree) == "stale since last build (2 files: 1 changed, 1 new)", "\(workingTree)")
        #expect(Self.semanticField(of: range) == Self.semanticField(of: workingTree), "\(range)")
    }

    /// An edited file in a directory no target compiles is refused as not built, never counted as changed since the build.
    @Test
    func anEditedFileNoTargetCompilesStaysNotBuilt() async throws {
        let root = try await Self.builtPackage()
        try TestSources.write(Self.loose + "// edited\n", to: "Extra/Unbuilt/Loose.swift", in: root)

        let output = try await Self.affected(root)

        #expect(output.contains("semantic: fresh, 2 declarations not found in the store"), "\(output)")
        #expect(output.contains("Extra/Unbuilt/Loose.swift has no unit in the store covering these declarations"), "\(output)")
        #expect(!output.contains("since the last build;"), "\(output)")
    }
}

private extension AffectedWorkingTreeJudgeTests {
    static var loose: String {
        "import Alpha\n\nstruct Loose {\n    func run() -> Int { Store().refresh() }\n}\n"
    }

    /// A committed package with targets `Alpha`, `Beta` depending on it, and `BetaTests`, plus a file no target compiles, built with its tests.
    static func builtPackage() async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\", dependencies: [\"Alpha\"]), .testTarget(name: \"BetaTests\", dependencies: [\"Beta\"])])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Store {\n    public init() {}\n    public func refresh() -> Int { 42 }\n}\n", to: "Sources/Alpha/Store.swift", in: root)
        try TestSources.write(Self.other(adding: "2"), to: "Sources/Beta/Other.swift", in: root)
        try TestSources.write("import Testing\n@testable import Beta\n\n@Test func goes() {\n    #expect(Other().go() == 44)\n}\n", to: "Tests/BetaTests/OtherTests.swift", in: root)
        try TestSources.write(Self.loose, to: "Extra/Unbuilt/Loose.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        return root
    }

    /// The built package with `Other.swift` edited after its unit and `Gizmo.swift` added to `Beta` with no unit, neither committed.
    static func editedPackage() async throws -> URL {
        let root = try await builtPackage()
        try TestSources.write(Self.other(adding: "3"), to: "Sources/Beta/Other.swift", in: root)
        try TestSources.write("import Alpha\n\npublic struct Gizmo {\n    public func run() -> Int { Store().refresh() }\n}\n", to: "Sources/Beta/Gizmo.swift", in: root)
        return root
    }

    static func other(adding addend: String) -> String {
        "import Alpha\n\npublic struct Other {\n    public init() {}\n    public func go() -> Int {\n        Store().refresh() + \(addend)\n    }\n}\n"
    }

    /// `affected` over the working tree, or over `range` where one is given, once the store has loaded.
    static func affected(_ root: URL, range: AffectedOptions.CommitRange? = nil) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: range, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// The header's `semantic:` field, or `nil` where the first line carries none.
    static func semanticField(of output: String) -> String? {
        let header = output.prefix { $0 != "\n" }
        guard let start = header.range(of: "semantic: ") else { return nil }
        return String(header[start.upperBound...])
    }
}
