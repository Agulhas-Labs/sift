//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the one thing the server suite's fixture builder can get wrong without any test noticing: how it reads the output of the `git` it runs.
///
/// A single pipe attached to both of git's streams and never read — not late, not on the failure path, not at all — passes while every fixture commits two files, because git has a few hundred bytes to say and the 64 KB a pipe holds is never reached; the first fixture that needs a hundred files hangs the suite with no failure to read. That is the whole hazard: a deadlock that cannot be observed until the day something makes it fire.
@Suite(.temporaryDirectories)
struct MCPTestRepoTests {
    /// A fixture whose creation prints past what a pipe holds is still made, rather than wedging the suite.
    ///
    /// The child is `git commit`, which prints `create mode 100644 <path>` for every file it adds, and the paths carry the bytes — so long names get past 64 KB in hundreds of writes rather than thousands.
    ///
    /// Waited on with a deadline rather than called and trusted to return, for `ProcessStreamsTests`' reason: `waitUntilExit` is a blocking wait that no cancellation reaches, so on a regression this reports a failure in half a minute instead of hanging the run with nothing to read.
    @Test
    func aFixtureWhoseCreationOverflowsThePipeIsStillMade() throws {
        let made = Made()
        let finished = DispatchSemaphore(value: 0)
        // Made on the test's task, where its scope is; the thread below is outside it.
        let directory = try TemporaryDirectory.make("mcp")
        let builder = Thread {
            do {
                made.root = try MCPTestRepo.make(at: directory, extraFiles: 1000)
            } catch {
                made.failure = "\(error)"
            }
            finished.signal()
        }
        builder.name = "sift.tests.mcp-fixture"
        builder.start()
        let returned = finished.wait(timeout: .now() + 30) == .success

        #expect(returned, "a fixture repo whose git output passes 64 KB must not deadlock the suite that builds it")
        #expect(made.failure == nil)
        let root = try #require(made.root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/App/Alpha.swift").path))
        // The premise, asserted rather than assumed: this fixture really does print past one pipe buffer,
        // so the test above is measuring the deadlock and not just a slow `git`.
        let created = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/App").path)
        #expect(created.map { "create mode 100644 Sources/App/\($0)\n".utf8.count }.reduce(0, +) > 64 * 1024)
    }
}

private extension MCPTestRepoTests {
    /// What the builder thread produced, handed back to the test that waited on it.
    ///
    /// Unchecked because the semaphore is the ordering: the writes happen before the signal and the reads after the wait, and on the deadline path neither field is read.
    final class Made: @unchecked Sendable {
        var root: URL?
        var failure: String?
    }
}
