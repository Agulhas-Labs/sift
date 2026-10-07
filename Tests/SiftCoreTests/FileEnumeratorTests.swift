//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The exclusions no configuration opts back in, and the hidden-directory rule above all.
///
/// A repository that vendors somebody else's tree under a dotted directory is the case that produced the rule: git tracks those files, so `git ls-files` lists them, and indexing them mints a module named after the directory that puts a guessed-module banner on every answer touching it.
@Suite(.temporaryDirectories)
struct FileEnumeratorTests {
    /// Source beside a vendored copy under a hidden directory, each with its own SwiftPM manifest, so a walk that entered the hidden tree would resolve a second module rather than merely index a second file.
    private static func makeTree() throws -> URL {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write(
            """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "App", targets: [.target(name: "App")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("struct A {}\n", to: "Sources/App/A.swift", in: root)
        try TestSources.write(
            """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Vendored", targets: [.target(name: "Vendored", path: "Sub")])
            """,
            to: ".vendor/Package.swift",
            in: root
        )
        try TestSources.write("struct B {}\n", to: ".vendor/Sub/B.swift", in: root)
        return root
    }

    @Test
    func aHiddenTreeGitTracksIsStillNotIndexed() throws {
        let root = try Self.makeTree()
        let enumerator = FileEnumerator(repoRoot: root, config: SiftConfig()) {
            ["Sources/App/A.swift", ".vendor/Package.swift", ".vendor/Sub/B.swift"]
        }

        #expect(enumerator.swiftFiles() == ["Sources/App/A.swift"])
        #expect(!enumerator.isIndexable(relativePath: ".vendor/Sub/B.swift"))
    }

    /// The fallback walk reaches the same answer as the git listing — the two enumeration paths cannot disagree about what is in the repository.
    @Test
    func theFallbackWalkNeverDescendsIntoAHiddenTree() throws {
        let root = try Self.makeTree()
        let enumerator = FileEnumerator(repoRoot: root, config: SiftConfig())

        #expect(enumerator.swiftFiles() == ["Sources/App/A.swift"])
    }

    /// The hidden tree contributes no manifest either, which is the half that would otherwise name a module for files the index will never hold.
    @Test
    func aManifestUnderAHiddenTreeNamesNoModule() throws {
        let root = try Self.makeTree()
        let scan = BuildFileScan.run(repoRoot: root, config: SiftConfig())
        let resolver = ModuleResolver(repoRoot: root, config: SiftConfig())

        #expect(scan.packageManifests.count == 1)
        #expect(scan.packageManifests.allSatisfy { !$0.path.contains("/.vendor/") })
        #expect(resolver.survey.swiftPMManifests == 1)
        #expect(resolver.resolvedModule(for: "Sources/App/A.swift") == "App")
        #expect(resolver.resolvedModule(for: ".vendor/Sub/B.swift") == nil)
    }

    /// A symbolic link to a Swift file is left out by both enumeration paths, so each file is held once, under the path git reports its edits on.
    @Test
    func aSymbolicLinkIsNeitherListedNorWalked() throws {
        let root = try Self.makeTree()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Sources/App/Link.swift").path, withDestinationPath: "A.swift")
        let listed = FileEnumerator(repoRoot: root, config: SiftConfig()) { ["Sources/App/A.swift", "Sources/App/Link.swift"] }
        let walked = FileEnumerator(repoRoot: root, config: SiftConfig())

        #expect(listed.swiftFiles() == ["Sources/App/A.swift"])
        #expect(walked.swiftFiles() == ["Sources/App/A.swift"])
        #expect(listed.exclusion(of: "Sources/App/Link.swift") == .symbolicLink)
    }
}
