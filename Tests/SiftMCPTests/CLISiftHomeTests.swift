//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A CLI call under `SIFT_HOME` writes its per-user state there and leaves the account's `~/.sift` alone.
///
/// Driven through the built binary, since the claim is about a process. The repository sits under the package's own `.build/`, not in a temporary directory: the roots registry deliberately never records a repository under `$TMPDIR`, and recording is what the test watches.
struct CLISiftHomeTests {
    @Test
    func aLookupRecordsItsRootUnderSiftHomeAndTouchesNoOtherHome() throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sift-home-\(UUID().uuidString)")
        let repo = Self.packageRoot.appendingPathComponent(".build/sift-home-repo-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: repo)
        }
        let sentinel = scratch.appendingPathComponent("home")
        let sentinelSift = sentinel.appendingPathComponent(".sift")
        try FileManager.default.createDirectory(at: sentinelSift, withIntermediateDirectories: true)
        try "kept".write(to: sentinelSift.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        _ = try MCPTestRepo.make(at: repo)
        let siftHome = scratch.appendingPathComponent("state")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["where", "Alpha", "--root", repo.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sentinel.path
        environment["CFFIXED_USER_HOME"] = sentinel.path
        environment["SIFT_HOME"] = siftHome.path
        for key in ["SIFT_USAGE_LOG", "SIFT_RUN_LOG", "SIFT_SERVER_LOG", "SIFT_ADVICE_DIR", "CLAUDE_CODE_SESSION_ID"] {
            environment[key] = nil
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let roots = try String(contentsOf: RootsRegistry.fileURL(in: siftHome), encoding: .utf8)
        #expect(roots.contains(repo.lastPathComponent), "the root was not recorded under SIFT_HOME: \(roots)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sentinelSift.path) == ["marker"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sentinel.path) == [".sift"])
    }
}

private extension CLISiftHomeTests {
    /// The package directory, from this file's own path.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
