//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the filesystem half of classifying a directory sweep, which is the only part of it that can be slow or wrong about a tree it has never seen.
@Suite(.temporaryDirectories)
struct SwiftTreeTests {
    private static func temporary() throws -> Harness {
        let root = try TemporaryDirectory.make("swifttree")
        return Harness(root: root, cleanup: { try? FileManager.default.removeItem(at: root) })
    }

    @Test
    func aDirectoryHoldingSwiftAnywhereBelowItCounts() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try harness.write("Sources/App/Deep/View.swift")

        #expect(SwiftTree.holdsSource(at: "Sources", relativeTo: harness.path))
        #expect(SwiftTree.holdsSource(at: harness.path + "/Sources/App", relativeTo: nil))
    }

    @Test
    func aTreeWithNoSwiftInItDoesNot() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try harness.write("Docs/Design.md")
        try harness.write("Web/index.html")

        #expect(!SwiftTree.holdsSource(at: "Docs", relativeTo: harness.path))
        #expect(!SwiftTree.holdsSource(at: "Missing", relativeTo: harness.path))
    }

    /// A relative path with nothing to resolve against is unanswerable, and answering "no" is what keeps the classifier text-only for a caller that has no working directory.
    @Test
    func aRelativePathWithNoDirectoryIsNotResolved() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try harness.write("Sources/View.swift")

        #expect(!SwiftTree.holdsSource(at: "Sources", relativeTo: nil))
        #expect(SwiftTree.probe(relativeTo: nil) == nil)
    }

    @Test
    func aSwiftFilePathCountsAndOnlyWhenItExists() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try harness.write("Sources/View.swift")

        #expect(SwiftTree.holdsSource(at: "Sources/View.swift", relativeTo: harness.path))
        #expect(!SwiftTree.holdsSource(at: "Sources/Gone.swift", relativeTo: harness.path))
    }

    /// Checkouts and dependency trees are full of Swift and are never what a lookup meant; walking them is also the expensive way to reach the wrong answer.
    @Test
    func generatedAndCheckoutDirectoriesAreNotWalked() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try harness.write(".build/checkouts/Dep/Sources/Dep.swift")
        try harness.write("node_modules/pkg/thing.swift")

        #expect(!SwiftTree.holdsSource(at: ".", relativeTo: harness.path))
    }

    // MARK: - isOutsideIndexedSources

    /// A repository that merely sits inside a directory named `checkouts` is indexed like any other — the indexer excludes that name only relative to the repository it walks, and Claude Code always hands a whole `Read` or an absolute `Grep` path an absolute path — so judging the raw path would refuse every file in it.
    @Test
    func aPathInsideARepositoryNamedLikeAnExcludedDirectoryIsStillInside() {
        #expect(!SwiftTree.isOutsideIndexedSources(
            "/Users/x/checkouts/App/Sources/View.swift",
            relativeTo: "/Users/x/checkouts/App/Sources"
        ))
        #expect(!SwiftTree.isOutsideIndexedSources(
            "/Users/x/checkouts/App/Tests/T.swift",
            relativeTo: "/Users/x/checkouts/App/Sources"
        ))
    }

    /// An excluded directory genuinely inside the tree the call's own `cwd` stands in is still outside, whichever of ``SwiftTree/neverIndexed`` it is named for.
    @Test
    func anExcludedDirectoryInsideTheCwdsTreeIsStillOutside() {
        #expect(SwiftTree.isOutsideIndexedSources(
            "/Users/x/checkouts/App/.build/checkouts/kit/A.swift",
            relativeTo: "/Users/x/checkouts/App"
        ))
        #expect(SwiftTree.isOutsideIndexedSources("/Users/x/App/Pods/Kit/File.swift", relativeTo: "/Users/x/App"))
        #expect(SwiftTree.isOutsideIndexedSources(
            "/Users/x/App/checkouts/Kit/File.swift",
            relativeTo: "/Users/x/App"
        ))
    }

    /// With no `cwd`, or a `cwd` sharing nothing with the path, the whole path is judged, as before this rule.
    @Test
    func withNoSharedCwdTheWholePathIsJudged() {
        #expect(SwiftTree.isOutsideIndexedSources("/Users/x/checkouts/App/Sources/View.swift"))
        #expect(SwiftTree.isOutsideIndexedSources(
            "/Users/x/checkouts/App/Sources/View.swift",
            relativeTo: "/Users/y/Other/Sources"
        ))
    }

    /// A relative path is judged as written, whether or not a `cwd` is given.
    @Test
    func aRelativePathIsJudgedAsWritten() {
        #expect(SwiftTree.isOutsideIndexedSources(".build/checkouts/kit/A.swift", relativeTo: "/Users/x/App"))
        #expect(!SwiftTree.isOutsideIndexedSources("Sources/View.swift", relativeTo: "/Users/x/checkouts/App"))
    }

    /// A `cwd` sitting inside `.build`, `DerivedData` or `node_modules` must not let the shared-prefix trick absorb that component away: those are never a repository's own ancestor, so a path under one is still outside even once the run it shares with `cwd` is dropped.
    ///
    /// `checkouts` keeps its carve-out — a `cwd` inside one, sharing nothing else with the excluded set, still judges what is left of the path as inside.
    @Test
    func aCwdInsideAnExcludedTreeDoesNotShareAwayTheExcludedComponent() {
        #expect(SwiftTree.isOutsideIndexedSources(
            "/repo/.build/checkouts/kit/Sources/Big.swift",
            relativeTo: "/repo/.build/checkouts/kit"
        ))
        #expect(SwiftTree.isOutsideIndexedSources(
            "/repo/DerivedData/Build/Products/A.swift",
            relativeTo: "/repo/DerivedData/Build/Products"
        ))
        #expect(SwiftTree.isOutsideIndexedSources(
            "/repo/node_modules/pkg/thing.swift",
            relativeTo: "/repo/node_modules/pkg"
        ))
        // `checkouts` is not a `neverAnAncestor`, so a `cwd` genuinely inside a directory named
        // `checkouts` shares that component away like any other, and the repository beneath it
        // stays inside — the carve-out the doc comment above promises.
        #expect(!SwiftTree.isOutsideIndexedSources(
            "/Users/x/checkouts/App/Sources/View.swift",
            relativeTo: "/Users/x/checkouts/App"
        ))
    }
}

private extension SwiftTreeTests {
    /// A throwaway tree and the tidy-up for it.
    struct Harness {
        let root: URL
        let cleanup: () -> Void

        var path: String {
            root.path
        }

        func write(_ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("//\n".utf8).write(to: url)
        }
    }
}
