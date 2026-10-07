//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers path canonicalisation: the comparison that decides whether a session is sitting in a repository it has already indexed.
@Suite(.temporaryDirectories)
struct CanonicalPathTests {
    /// Whether this volume is the case-insensitive kind, asked rather than assumed.
    ///
    /// The behaviour under test is a property of the volume, so on a case-sensitive one there is nothing here to check and folding the two spellings together would be the bug rather than the fix.
    private static func caseInsensitive(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path.uppercased())
            && FileManager.default.fileExists(atPath: directory.path.lowercased())
    }

    @Test
    func aPathIsStandardisedAndStrippedOfATrailingSlash() {
        #expect(CanonicalPath.of("/a/b/../b/") == "/a/b")
    }

    /// A path that is not there has to keep comparing equal to itself: pruned roots and test fixtures are ordinary.
    @Test
    func aPathThatDoesNotExistFallsBackToItsStandardisedForm() {
        let missing = "/definitely/not/here-\(UUID().uuidString)"

        #expect(CanonicalPath.of(missing) == missing)
    }

    /// The failure this guards: the primer announcing an indexed repository as unindexed because the shell's `cwd` is cased differently from the registry's copy.
    @Test
    func twoSpellingsOfOneDirectoryCanonicaliseTogether() throws {
        let root = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixed = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent.uppercased())
        try #require(Self.caseInsensitive(at: root), "case-sensitive volume — nothing to fold")

        #expect(CanonicalPath.of(mixed.path) == CanonicalPath.of(root.path))
    }

    /// The end of the chain where the mismatch surfaces.
    @Test
    func aDifferentlyCasedCwdIsStillInsideItsIndexedRoot() throws {
        let root = try TestSources.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(Self.caseInsensitive(at: root), "case-sensitive volume — nothing to fold")
        let shouted = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent.uppercased()).path

        let context = SessionPrimer.context(
            cwd: shouted,
            knownRoots: [root.path],
            repositoryRoot: nil,
            containsSwiftSources: false
        )

        #expect(context == .insideRoot(CanonicalPath.of(root.path)))
    }
}
