//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the answer to a file digest that finds no indexed file: a file that exists but that a rule of the index keeps out is told that rule, a path spelled other than repo-relative is read as the file it names, and a path that names nothing keeps the plain miss.
///
/// Every fixture file but the gitignored one is committed, because the case this answers is a file git tracks — a tool's tree vendored under a hidden directory — that the index still leaves out by design. "No indexed file matches" about it reads as "there is no such file", and sends the caller looking for one that was never missing.
@Suite(.temporaryDirectories)
struct ExcludedFileDigestTests {
    private static var readAdvice: String {
        "A plain Read is the way to see it: nothing in it is in the index."
    }

    private static func engine(config: String? = nil, at root: URL? = nil) async throws -> SiftEngine {
        let root = try root.map(TestSources.makeTempRepo(at:)) ?? TestSources.makeTempRepo()
        try TestSources.write("struct Anchor {}\n", to: "Sources/App/Anchor.swift", in: root)
        try TestSources.write("struct Rule {}\n", to: ".tooling/Lint/Rule.swift", in: root)
        try TestSources.write("struct Model {}\n", to: "Sources/App/Generated/Model.swift", in: root)
        try TestSources.write("struct Page {}\n", to: "Web/Page.swift", in: root)
        try TestSources.write("notes\n", to: "Web/notes.txt", in: root)
        if let config {
            try TestSources.write(config, to: ".sift.json", in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    @Test
    func aTrackedFileUnderAHiddenDirectoryIsSaidToBeExcluded() async throws {
        let engine = try await Self.engine()

        let answer = try engine.digest(target: ".tooling/Lint/Rule.swift", options: DigestOptions())

        #expect(answer == ".tooling/Lint/Rule.swift exists but is not indexed — .tooling is hidden, and a hidden path is never indexed. \(Self.readAdvice)")
    }

    @Test
    func aFileTheConfigExcludesNamesThePattern() async throws {
        let engine = try await Self.engine(config: "{\n  \"exclude\": [\"Generated/\"]\n}\n")

        let answer = try engine.digest(target: "Sources/App/Generated/Model.swift", options: DigestOptions())

        #expect(answer == "Sources/App/Generated/Model.swift exists but is not indexed — .sift.json excludes paths containing \"Generated/\". \(Self.readAdvice)")
    }

    @Test
    func aFileOutsideTheConfiguredRootsNamesTheRoots() async throws {
        let engine = try await Self.engine(config: "{\n  \"roots\": [\"Sources\"]\n}\n")

        let answer = try engine.digest(target: "Web/Page.swift", options: DigestOptions())

        #expect(answer == "Web/Page.swift exists but is not indexed — .sift.json limits the index to Sources. \(Self.readAdvice)")
    }

    /// The index's own rules are named the same way as a repository's, since a caller cannot tell them apart from the outside.
    ///
    /// A `.md` file is no longer one of these: it is served its heading outline, read live from disk (`MarkdownOutlineDigestTests`), so the non-Swift file that stands for the rule here is a plain text one.
    @Test
    func aManifestAndANonSwiftFileNameTheIndexsOwnRules() async throws {
        let engine = try await Self.engine()
        try TestSources.write("// swift-tools-version:5.9\nimport PackageDescription\n", to: "Web/Package.swift", in: engine.repoRoot)

        let manifest = try engine.digest(target: "Web/Package.swift", options: DigestOptions())
        let notes = try engine.digest(target: "./Web/notes.txt", options: DigestOptions())

        #expect(manifest == "Web/Package.swift exists but is not indexed — it is a build manifest, which the index reads to resolve modules and never stores as source. \(Self.readAdvice)")
        #expect(notes == "Web/notes.txt exists but is not indexed — the index holds Swift sources only. \(Self.readAdvice)")
    }

    /// The index stores repo-relative paths, so every other spelling of an indexed file's path has to be read as that one before "no indexed file matches" can be said about it.
    @Test
    func anAbsoluteOrDottedPathFindsTheFileItNames() async throws {
        let engine = try await Self.engine()
        let root = engine.repoRoot.path
        // The same root through the symlink the system's temporary directory sits behind, where there is one.
        let symlinked = root.hasPrefix("/private/") ? String(root.dropFirst("/private".count)) : root

        let absolute = try engine.digest(target: root + "/Sources/App/Anchor.swift", options: DigestOptions())
        let throughLink = try engine.digest(target: symlinked + "/Sources/App/Anchor.swift", options: DigestOptions())
        let dotted = try engine.digest(target: "./Sources/App/../App/Anchor.swift", options: DigestOptions())
        let excluded = try engine.digest(target: root + "/.tooling/Lint/Rule.swift", options: DigestOptions())

        #expect(absolute.contains("struct Anchor {}"))
        #expect(throughLink.contains("struct Anchor {}"))
        #expect(dotted.contains("struct Anchor {}"))
        #expect(excluded == ".tooling/Lint/Rule.swift exists but is not indexed — .tooling is hidden, and a hidden path is never indexed. \(Self.readAdvice)")
    }

    /// Git's ignore rules are applied by the listing the index is built from rather than by a rule of its own, so they are asked of git — and only for a file on disk that no other rule accounts for.
    @Test
    func aFileGitIgnoresIsSaidToBeIgnored() async throws {
        let engine = try await Self.engine()
        try TestSources.write("Scratch/\n", to: ".gitignore", in: engine.repoRoot)
        try TestSources.commitAll(in: engine.repoRoot, message: "ignore")
        try TestSources.write("struct Draft {}\n", to: "Sources/App/Scratch/Draft.swift", in: engine.repoRoot)
        try TestSources.write("struct Draft {}\n", to: ".tooling/Scratch/Draft.swift", in: engine.repoRoot)

        let ignored = try engine.digest(target: "Sources/App/Scratch/Draft.swift", options: DigestOptions())
        let hiddenToo = try engine.digest(target: ".tooling/Scratch/Draft.swift", options: DigestOptions())

        #expect(ignored == "Sources/App/Scratch/Draft.swift exists but is not indexed — git ignores it. \(Self.readAdvice)")
        #expect(hiddenToo == ".tooling/Scratch/Draft.swift exists but is not indexed — .tooling is hidden, and a hidden path is never indexed. \(Self.readAdvice)")
    }

    /// A found-but-excluded file is not a miss — it named exactly the file the target asked for, and said why it isn't indexed — unlike a target that named nothing at all.
    ///
    /// The face reads `missed` to decide whether a caller's spaced target most likely meant several names run together; conflating the two turns a right answer into a wrong suggestion.
    @Test
    func anExcludedFileIsNotMarkedAsAMissButAPlainMissIs() async throws {
        let engine = try await Self.engine()
        try TestSources.write("Scratch/\n", to: ".gitignore", in: engine.repoRoot)
        try TestSources.commitAll(in: engine.repoRoot, message: "ignore")
        try TestSources.write("struct Draft {}\n", to: "Sources/App/Scratch/Draft.swift", in: engine.repoRoot)

        let excluded = try engine.measuredDigest(target: "Sources/App/Scratch/Draft.swift", options: DigestOptions())
        let miss = try engine.measuredDigest(target: "Sources/App/Nowhere.swift", options: DigestOptions())

        #expect(!excluded.missed)
        #expect(miss.missed)
    }

    @Test
    func aPathThatNamesNoFileKeepsThePlainMiss() async throws {
        let engine = try await Self.engine()

        let answer = try engine.digest(target: "Sources/App/Nowhere.swift", options: DigestOptions())

        #expect(answer == "no indexed file matches Sources/App/Nowhere.swift")
    }

    /// `..` is a name starting with a dot, so a path climbing out of the repository must not be read as one under a hidden directory — a file beside the repository is not one this index could have held.
    @Test
    func aPathLeavingTheRepositoryKeepsThePlainMiss() async throws {
        let container = try TestSources.makeTempDirectory()
        try TestSources.write("struct Stray {}\n", to: "Stray.swift", in: container)
        let engine = try await Self.engine(at: container.appendingPathComponent("repo"))

        let answer = try engine.digest(target: "../Stray.swift", options: DigestOptions())

        #expect(answer == "no indexed file matches ../Stray.swift")
    }
}
