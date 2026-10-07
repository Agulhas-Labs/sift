//
// Copyright © Agulhas Labs
//

import Foundation

/// Both of a child process's streams, read to end at the same time.
///
/// **Reading one to EOF before starting on the other is a deadlock, not a matter of style.** A pipe holds 64 KB; a child that fills stderr before it closes stdout then blocks in `write` while this side blocks in `read`, and neither ever moves again. Every caller here is synchronous and none has a timeout, so the hang is the whole command's — on the strength of a subprocess having had a lot to say.
///
/// It exists as a type of its own because the same three lines are easy to write twice and fix once. `git ls-files` on a monorepo and `git diff --name-only` on a dirty tree are both perfectly capable of the volume this needs, so a private helper on whichever type noticed first is a fix that leaves the next caller to rediscover the bug.
public struct ProcessStreams: Sendable {
    private init() {}
}

public extension ProcessStreams {
    /// The child's stdout and stderr, each read to end, whichever the child chose to fill first, with both read ends closed once they are.
    ///
    /// **Closing is this side's job and nobody else's.** `Process` closes the child's ends of the pipes once it has spawned, but a read end stays open for as long as this process lives; a long-lived caller that spawns per lookup then runs the kernel out of pipes, and every spawn after that throws.
    ///
    /// Reading stderr on a thread of its own is what removes the ordering from the question entirely: both handles reach end before the caller waits on the process.
    ///
    /// **A thread, deliberately, and not a `DispatchQueue`.** Dispatching the stderr read onto a private serial queue would target the non-overcommit global root queue and therefore have to *wait for a worker thread*. In a process whose pool is already full of threads blocked on subprocesses that block never starts, the child fills stderr and blocks in `write`, this side blocks reading stdout, and the deadlock the whole type exists to prevent is back with a new cause. A `Thread` is allocated on the spot and owes nothing to a pool, which is the right primitive for a blocking read that must begin now.
    ///
    /// The hazard is reasoned rather than observed on this path, and it is closed anyway: a pool can withhold a thread for longer than ten seconds under load, which is all this path needs to hang for good.
    static func drain(stdout: Pipe, stderr: Pipe) -> (output: Data, failure: Data) {
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            collected.value = stderr.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        reader.name = "sift.process-streams.stderr"
        reader.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return (output, collected.value)
    }

    /// The same, read only until `deadline`, with both read ends closed either way; `complete` says whether both reached end of file in time.
    ///
    /// **One thread waiting on both descriptors with `poll(2)`**, which reads whichever has bytes, so neither ordering nor a thread pool can stall it; and the wait ends at the deadline even while some process still holds a write end open. A blocking `readDataToEndOfFile` cannot be given a deadline, and closing its handle from another thread to unblock it makes `FileHandle` raise.
    static func drain(stdout: Pipe, stderr: Pipe, until deadline: DispatchTime) -> Drained {
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        var collected = [Data(), Data()]
        var open = [true, true]
        var buffer = [UInt8](repeating: 0, count: 65536)
        while open.contains(true) {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { break }
            let milliseconds = Int32(clamping: (deadline.uptimeNanoseconds - now) / 1_000_000 + 1)
            var watched = descriptors.indices.filter { open[$0] }.map { pollfd(fd: descriptors[$0], events: Int16(POLLIN), revents: 0) }
            let ready = poll(&watched, nfds_t(watched.count), milliseconds)
            if ready < 0 {
                guard errno == EINTR else { break }
                continue
            }
            for entry in watched where entry.revents != 0 {
                guard let index = descriptors.firstIndex(of: entry.fd) else { continue }
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    collected[index].append(contentsOf: buffer[0 ..< count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    open[index] = false
                }
            }
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return Drained(output: collected[0], failure: collected[1], complete: !open.contains(true))
    }

    /// What a drain with a deadline read: both streams' bytes, and whether both reached end of file in time.
    struct Drained: Sendable {
        public let output: Data
        public let failure: Data
        public let complete: Bool
    }

    /// Closes both ends of every pipe in `pipes`, for a child that never started.
    ///
    /// `Process` closes the child's ends of its pipes only once it has launched, so a launch that throws, a working directory gone from disk among the causes, leaves both ends of each open for as long as this process lives unless the caller closes them here.
    static func abandon(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}

extension ProcessStreams {
    /// One stream's bytes, handed back from the thread that read them.
    ///
    /// Unchecked because the ordering is the lock: the write happens before the semaphore is signalled and the read after the wait returns, which is a happens-before edge and not a hope about timing.
    private final class Collected: @unchecked Sendable {
        var value = Data()
    }
}
