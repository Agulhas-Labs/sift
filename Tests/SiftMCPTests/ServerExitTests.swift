//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the property that decides whether a lost session leaves a clean exit or an orphan: `sift mcp` ends when its input does.
///
/// **Why this is a subprocess test and not a unit one.** The read loop returning is only half of it. The other half is what the *process* does next, and that is a property of the async main this command runs under rather than of any type here — no in-process assertion can see it. Being true incidentally is not enough; it has to be true on purpose.
///
/// The failure it guards against: a `sift mcp` process alive for hours with its client socket still open, its parent `claude` still running, and its main thread parked in the dispatch run loop — not blocked in a syscall, simply never reading again. A server in that state holds a repository's `index.db` and an IndexStoreDB lock directory keyed to its own pid, answers nothing, and is invisible to the client, which reports the tools as gone. The difference between that and a clean exit the host could notice is exactly this test.
@Suite(.serialized, .temporaryDirectories)
struct ServerExitTests {
    /// Closing the client's end ends the process, promptly and with a success status.
    @Test
    func theServerExitsWhenItsClientClosesTheInput() throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let directory = try TemporaryDirectory.make("exit")
        let log = directory.appendingPathComponent("server.jsonl")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"]
        // Pointed at a temporary log so a test never appends to the record a human reads to diagnose a real drop.
        var environment = ProcessInfo.processInfo.environment
        environment["SIFT_SERVER_LOG"] = log.path
        environment["SIFT_USAGE_LOG"] = directory.appendingPathComponent("usage.jsonl").path
        environment["SIFT_ADVICE_DIR"] = directory.appendingPathComponent("advice").path
        process.environment = environment
        let toServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        toServer.fileHandleForWriting.closeFile()
        let exited = Self.wait(for: process, seconds: 30)

        #expect(exited, "sift mcp was still running 30s after its input closed — a client that hangs up must not leave a server behind")
        #expect(process.terminationStatus == 0)
        // And it said so on the way out, which is what turns a drop into a reading rather than a guess.
        let recorded = ServerLifecycleReport.entries(in: log)
        #expect(recorded.last?.event == "stop")
        #expect(recorded.last?.reason == "input-closed")
        // One stop per start. The signal path and the ordinary path share a guard so a `SIGHUP` landing as the
        // client hangs up cannot record twice against one start — a race this cannot reproduce on demand, so
        // what is pinned here is the ordinary half of it.
        #expect(recorded.filter { $0.event == "stop" }.count == 1)
    }

    /// Polls rather than blocking on `waitUntilExit`, so a server that never exits fails the test instead of hanging the suite.
    private static func wait(for process: Process, seconds: Int) -> Bool {
        let deadline = Date() + Double(seconds)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        let running = process.isRunning
        if running {
            process.terminate()
        }
        return !running
    }
}
