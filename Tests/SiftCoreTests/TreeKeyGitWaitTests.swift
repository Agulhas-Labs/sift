//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The tree hashes a `sift run` takes around every build and test spend their time in git, not in waiting for git.
///
/// Pinned on the source because the cost it guards is not deterministic: `Process.waitUntilExit` sleeps in a run loop for about 65 ms only when the child has not been reaped by the time it is called, so a timing test passes on a quiet machine whichever wait is written. What is fixed is the property: the code of each hash awaits its git's exit on a termination handler, and a key asks git for the repository's directories once.
struct TreeKeyGitWaitTests {
    private static let sources = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root
        .appending(path: "Sources/SiftCore")

    /// The code of one source file, its comments and string literals blanked.
    private static func code(of file: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let bytes = try [UInt8](Data(contentsOf: sources.appending(path: file)))
        let code = try #require(String(bytes: ExampleNameScanner.split(swift: bytes).code, encoding: .utf8), sourceLocation: sourceLocation)
        try #require(!code.isEmpty, sourceLocation: sourceLocation)
        return code
    }

    /// The tree key's git calls are awaited on the termination handler, never on the blocking wait.
    @Test func theTreeKeyAwaitsGitOnItsTerminationHandler() throws {
        let code = try Self.code(of: "TreeKey.swift")

        #expect(!code.contains("waitUntilExit"))
    }

    /// The content hash a test run keys its flakes by awaits its git calls the same way.
    @Test func theContentHashAwaitsGitOnItsTerminationHandler() throws {
        let code = try Self.code(of: "TreeContentHash.swift")

        #expect(!code.contains("waitUntilExit"))
    }

    /// The tree key hands the common directory it already holds to the exclude step, rather than the form that asks git for it again.
    @Test func theTreeKeyAsksGitForItsDirectoriesOnce() throws {
        let code = try Self.code(of: "TreeKey.swift")

        #expect(code.components(separatedBy: "ensureCacheExcluded(").count == 2)
        #expect(!code.contains("ensureCacheExcluded()"))
    }
}
