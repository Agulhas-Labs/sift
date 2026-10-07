//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A git call from a directory that no longer exists is a failed call, never a crash.
///
/// The audit's replay asks for the repository holding each worktree a transcript names, and a worktree removed since the session ran hands `Process` a working directory it cannot enter — which it answers with an Objective-C exception nothing in Swift can catch, taking the whole `sift audit --replay` down with it.
@Suite(.temporaryDirectories)
struct GitContextGoneDirectoryTests {
    /// The root of a directory that is gone is no root at all, and asking for it leaves the process alive to say so.
    @Test
    func theRootOfAGoneDirectoryIsNilNotACrash() throws {
        let gone = try TemporaryDirectory.make("gone")
        try FileManager.default.removeItem(at: gone)

        #expect(GitContext.spawnedRoot(from: gone) == nil)
        #expect(GitContext.discoverRoot(from: gone) == nil)
    }

    /// A gone worktree spelled relative in a transcript asks for the root of `/..`, which `Process` refuses with an exception it cannot be asked to catch; standardised, it is the root directory, which holds no repository.
    @Test
    func theRootOfAnUnenterablePathIsNil() {
        #expect(GitContext.spawnedRoot(from: URL(fileURLWithPath: "/..", isDirectory: true)) == nil)
    }

    /// A path that names a file rather than a directory is refused the same way.
    @Test
    func theRootAskedFromAFileIsNil() throws {
        let holder = try TemporaryDirectory.make("gone-file")
        defer { try? FileManager.default.removeItem(at: holder) }
        let file = holder.appendingPathComponent("plain.txt")
        try Data("not a directory".utf8).write(to: file)

        #expect(GitContext.spawnedRoot(from: file) == nil)
    }
}
