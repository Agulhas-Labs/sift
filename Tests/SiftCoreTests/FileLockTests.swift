//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one property that keeps a ledger from becoming a precondition for the work it records.
@Suite(.temporaryDirectories)
struct FileLockTests {
    private static func temporaryFile() throws -> URL {
        let directory = try TemporaryDirectory.make("lock")
        let fileURL = directory.appendingPathComponent("locked")
        try Data().write(to: fileURL)
        return fileURL
    }

    @Test
    func anUncontendedLockIsTakenAndReleased() throws {
        let fileURL = try Self.temporaryFile()
        let descriptor = open(fileURL.path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        #expect(FileLock.take(descriptor, .exclusive))
        FileLock.release(descriptor)
        #expect(FileLock.take(descriptor, .exclusive))
    }

    /// A contended lock gives up quickly rather than waiting on whoever holds it.
    ///
    /// This is the property three docstrings in this tree already promise — *"nothing here may raise or block; a ledger is a record of work, never a precondition for it"* — and which a blocking `flock` quietly breaks. It matters because `MCPServer` appends to the usage log *between* a tool call and its answer, so a pathological holder would stall every index call in every concurrent session, and `sift status` with them: the command someone runs to diagnose a hang, hanging. Unbounded, a holder keeping the lock for twenty seconds stalls every such caller for about as long.
    @Test
    func aContendedLockGivesUpInsteadOfWaiting() throws {
        let fileURL = try Self.temporaryFile()
        let holder = open(fileURL.path, O_RDWR)
        #expect(holder >= 0)
        #expect(flock(holder, LOCK_EX) == 0)
        defer { close(holder) }

        let waiter = open(fileURL.path, O_RDWR)
        #expect(waiter >= 0)
        defer { close(waiter) }

        // Attempted off this thread with a deadline, so an implementation that goes back to blocking turns the
        // suite red rather than wedging it — a hang is the harm being tested for, and no harm belongs in the
        // runner itself.
        let outcome = LockOutcome()
        let finished = DispatchSemaphore(value: 0)
        let attempt = Thread {
            outcome.record(FileLock.take(waiter, .exclusive))
            finished.signal()
        }
        attempt.start()
        let settled = finished.wait(timeout: .now() + 5) == .success
        // Released whatever happened, so a blocking attempt can finish and this thread does not outlive the test.
        flock(holder, LOCK_UN)
        if !settled {
            _ = finished.wait(timeout: .now() + 5)
        }

        #expect(settled, "FileLock.take was still waiting after 5s for a lock it was supposed to give up on")
        #expect(outcome.taken == false, "the lock is held by another descriptor and cannot have been taken")
    }
}

private extension FileLockTests {
    /// What the attempt on the other thread came back with.
    final class LockOutcome: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: Bool?

        func record(_ taken: Bool) {
            mutex.lock()
            defer { mutex.unlock() }
            value = taken
        }

        var taken: Bool? {
            mutex.lock()
            defer { mutex.unlock() }
            return value
        }
    }
}
