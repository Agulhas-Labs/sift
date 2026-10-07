//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one helper every subprocess in this module reads its output through.
///
/// It lives in a file of its own rather than beside either caller because both `GitContext.run` and `RunChangedFiles.inWorkingTree` depend on it, and a private helper on whichever type noticed the bug would leave the other caller deadlocking on identical code twenty lines away. A test filed under one of them would have said the same thing about where the rule lives.
@Suite(.temporaryDirectories)
struct ProcessStreamsTests {
    /// A child that fills one pipe before it touches the other is read to the end all the same, rather than deadlocking the command that is waiting on it.
    ///
    /// A pipe holds 64 KB. Draining stdout to EOF first means a child with more than that to say on stderr blocks in `write` while this side blocks in `read` — forever, with no timeout, on a path a caller waits on synchronously. `git` cannot be made to produce that on demand, so the child here is written to order: 200 KB to stderr, past the buffer three times over, and only then a byte on stdout.
    ///
    /// The drain runs on a thread of its own and is *waited* on with a deadline, rather than being called here and trusted to return. Both halves of that are the point. `readDataToEndOfFile` is a blocking read that no task cancellation reaches, so `.timeLimit` cannot end it and the wrong ordering would hang the whole suite instead of failing this test — a gate that never reports is worse than none. And the child is killed when the deadline passes, which closes the write ends and lets the stuck reader finish, so a regression costs ten seconds and one failure rather than a wedged process for the rest of the run.
    ///
    /// **A `Thread`, not `DispatchQueue.global()`**: a dispatched block has to be *given* a worker, and in a suite that stands up fixture packages the pool can have none to give for longer than this deadline — so the block never runs, the deadline passes, and the test reports a deadlock in code that is working. A harness measuring whether something starts within ten seconds must not itself queue behind the load. `ProcessStreams.drain` makes the same choice for the same reason, where the failure would be a hang rather than a false failure.
    @Test
    func aChildFillingStderrFirstIsStillReadToTheEnd() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for i in $(seq 1 2000); do printf '%0100d\\n' $i >&2; done; printf 'done\\n'"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let drained = Drained()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            drained.streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
            finished.signal()
        }
        reader.start()
        let returned = finished.wait(timeout: .now() + 10) == .success
        if !returned {
            process.terminate()
        }
        process.waitUntilExit()

        #expect(returned, "reading one stream to the end before the other deadlocks on a child that fills it")
        let streams = try #require(drained.streams)
        #expect(String(bytes: streams.output, encoding: .utf8) == "done\n")
        #expect(streams.failure.count > 200_000)
        #expect(process.terminationStatus == 0)
    }

    /// The mirror case, because a fix that only reads stderr early would pass the test above and fail this one.
    ///
    /// Here the child fills *stdout* past the buffer before saying anything on stderr. Both orderings have to survive, since which stream a subprocess fills first is its business — `git ls-files` on a monorepo fills stdout, a refusal's usage advice fills stderr.
    @Test
    func aChildFillingStdoutFirstIsAlsoReadToTheEnd() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for i in $(seq 1 2000); do printf '%0100d\\n' $i; done; printf 'oops\\n' >&2"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let drained = Drained()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            drained.streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
            finished.signal()
        }
        reader.start()
        let returned = finished.wait(timeout: .now() + 10) == .success
        if !returned {
            process.terminate()
        }
        process.waitUntilExit()

        #expect(returned, "a child filling stdout past the pipe buffer must not deadlock either")
        let streams = try #require(drained.streams)
        #expect(streams.output.count > 200_000)
        #expect(String(bytes: streams.failure, encoding: .utf8) == "oops\n")
        #expect(process.terminationStatus == 0)
    }

    /// `GitContext` reads its subprocess through the same helper, so a repository whose file list overflows the pipe answers rather than hanging.
    ///
    /// Not a second deadlock test — `run` is private and `git` will not fill stderr to order, which is why the two above drive the helper directly. This one pins the thing that can actually regress: that `GitContext` goes through `ProcessStreams` at all. Restore its own sequential read and a `git ls-files` over 1,000 files still returns, but the helper stops being the single implementation and the next caller inherits the bug again.
    @Test
    func gitContextReadsALongFileListThroughTheSharedDrain() throws {
        let root = try TestSources.makeTempRepo()
        // The paths have to carry the bytes, not the file contents: `git ls-files` prints names, so a
        // thousand one-line files still fits in one buffer. Long names get past 64 KB in 1,000 writes
        // rather than the ~2,300 the short ones would need, which keeps this test under a second.
        let padding = String(repeating: "Nested", count: 8)
        for index in 0 ..< 1000 {
            try TestSources.write("let value\(index) = \(index)\n", to: "Sources/\(padding)/File\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many files")

        let visible = try GitContext(repoRoot: root).visibleSwiftFiles()

        // Comfortably past the 64 KB a pipe holds, so the read genuinely spans more than one buffer.
        #expect(visible.count >= 1000)
        #expect(visible.joined(separator: "\n").utf8.count > 64 * 1024)
    }

    /// `GitContext.blobs(_:)` feeds `cat-file --batch` its requests on a pipe, written from a thread of its own, rather than through a temp file — so a batch whose input and output each overflow a pipe's 64 KB buffer must still answer every request, in order, rather than the write and the drain deadlocking each other.
    ///
    /// Pins the fix: a batch input written to `$TMPDIR` before `git` ran, and removed in a `defer`, leaked whenever the process was cut off before the `defer` ran — the session-start gather's 1.5s deadline being exactly that case. The pipe writes nothing to disk, so there is nothing left for a cut-off to leak.
    ///
    /// The path is long and the request count high rather than the blob itself, so the *input* line list clears 64 KB many times over — `content.txt` asked for 3005 times, the shape this test carried before, is only ~51 KB, comfortably under the buffer a synchronous write-then-drain would still pass. A path of ~200 characters asked for ~5,000 times puts the request list past 1 MB, genuinely spanning several buffers' worth on both the way in and the way out. `.timeLimit` fails the test on a hang rather than leaving the suite stuck with no report.
    @Test(.timeLimit(.minutes(1)))
    func blobsAnswersABatchThatOverflowsBothPipeBuffers() throws {
        let root = try TestSources.makeTempRepo()
        let segment = String(repeating: "Nested", count: 4)
        let directories = Array(repeating: segment, count: 8).joined(separator: "/")
        let path = "\(directories)/Content.txt"
        #expect(path.utf8.count > 190)
        try TestSources.write(String(repeating: "x", count: 100), to: path, in: root)
        try TestSources.commitAll(in: root, message: "add content")

        var requests = (0 ..< 5000).map { _ in (rev: "HEAD", path: path) }
        requests += (0 ..< 5).map { index in (rev: "HEAD", path: "missing-\(index).txt") }

        let results = try GitContext(repoRoot: root).blobs(requests)

        #expect(results.count == requests.count)
        for index in 0 ..< 5000 {
            #expect(results[index] == Data(String(repeating: "x", count: 100).utf8))
        }
        for index in 5000 ..< requests.count {
            #expect(results[index] == nil)
        }
    }
}

private extension ProcessStreamsTests {
    /// What the drain returned, handed back from the thread that waited on it.
    ///
    /// Unchecked because the semaphore is the ordering: the write happens before the signal and the read after the wait, and on the deadline path the value is only ever read as `nil`.
    final class Drained: @unchecked Sendable {
        var streams: (output: Data, failure: Data)?
    }
}
