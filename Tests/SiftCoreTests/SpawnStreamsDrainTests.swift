//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how a spawn's pipes are read: without ever blocking the queue that closes them, and to the last byte the child left in them.
///
/// The pipes are made here rather than by a spawn wherever the case needs to hold the reading queue still, since only then is the moment the sources are cancelled one the case decides rather than one it races.
struct SpawnStreamsDrainTests {
    /// Both read ends are non-blocking from the moment they are watched, so no read can hold the queue that closes them.
    @Test
    func bothReadEndsAreNonBlockingOnceWatched() {
        let output = Pipe()
        let errors = Pipe()
        let streams = SimulatorAccessibility.SpawnStreams(standardOutput: output, standardError: errors)
        for pipe in [output, errors] {
            let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
            #expect(flags & O_NONBLOCK != 0, "the read end's flags are \(flags)")
        }
        _ = streams.collected()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    /// What is in the pipes when the sources are cancelled is still collected, though no event for it was ever handled.
    ///
    /// The reading queue is held busy while the bytes are written and is let go only after the sources have been cancelled, so no event handler ever sees them: they come back only if the cancel handlers read what is left before closing. The write ends stay open throughout, as a grandchild's would, so a final read that blocked would hold the close past the call.
    @Test
    func whatThePipesHoldWhenTheSourcesAreCancelledIsStillCollected() {
        let queue = DispatchQueue(label: "SpawnStreamsDrainTests")
        let output = Pipe()
        let errors = Pipe()
        let streams = SimulatorAccessibility.SpawnStreams(standardOutput: output, standardError: errors, queue: queue)
        let busy = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        queue.async {
            busy.signal()
            held.wait()
        }
        busy.wait()
        output.fileHandleForWriting.write(Data("bye".utf8))
        errors.fileHandleForWriting.write(Data("gone".utf8))
        // A thread of its own rather than a dispatch worker, which a loaded suite can starve past the grace the
        // cancel handlers are waited for; the pause is well inside that grace and long after `collected` cancels.
        let collecting = DispatchSemaphore(value: 0)
        let release = Thread {
            collecting.wait()
            Thread.sleep(forTimeInterval: 0.03)
            held.signal()
        }
        release.start()
        collecting.signal()
        let collected = streams.collected()
        #expect(collected.standardOutput == "bye")
        #expect(collected.standardError == "gone")
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
    }

    /// A read event that finds nothing to read leaves the stream open, so what is written afterwards is still collected.
    ///
    /// The reading queue is held while a byte is written and taken out of the pipe directly, so the event that byte raised is handled only once the pipe is empty and its read fails as not ready yet. Were that taken for the end of the file, the stream would end there, the later byte would come back only from the final read at cancel, and the wait for the end would run to its limit.
    @Test
    func anEventThatFindsNothingDoesNotEndTheStream() {
        let queue = DispatchQueue(label: "SpawnStreamsDrainTests.empty")
        let output = Pipe()
        let errors = Pipe()
        let streams = SimulatorAccessibility.SpawnStreams(standardOutput: output, standardError: errors, queue: queue)
        let busy = DispatchSemaphore(value: 0)
        let held = DispatchSemaphore(value: 0)
        queue.async {
            busy.signal()
            held.wait()
        }
        busy.wait()
        output.fileHandleForWriting.write(Data("a".utf8))
        var taken = [UInt8](repeating: 0, count: 8)
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &taken, taken.count)
        #expect(count == 1, "the direct read returned \(count)")
        held.signal()
        // The queue is idle again once this returns, so the pending event has found the pipe empty.
        queue.sync {}
        output.fileHandleForWriting.write(Data("b".utf8))
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let started = ContinuousClock.now
        streams.waitForEnd(within: 5)
        let waited = ContinuousClock.now - started
        let collected = streams.collected()
        #expect(collected.standardOutput == "b")
        #expect(waited < .seconds(2), "both ends were closed, yet the wait ran \(waited)")
    }

    /// A child that answers the polite signal by saying something and exiting has that last word in what a timed-out spawn returns.
    ///
    /// This is a smoke test and pins nothing of the final read, which the exit of the child usually delivers through an ordinary event anyway; the real pin is the case above that holds the reading queue while the sources are cancelled.
    @Test
    func whatAChildSaysAsItIsEndedComesBack() throws {
        let script = "trap 'echo bye; kill $!; exit 0' TERM; sleep 5 >/dev/null 2>&1 & wait"
        let output = try SimulatorAccessibility.spawn("/bin/sh", ["-c", script], deadline: 0.2)

        #expect(output.standardError.contains("timed out"), "\(output.standardError)")
        #expect(output.standardOutput.contains("bye"), "\(output.standardOutput)")
    }
}
