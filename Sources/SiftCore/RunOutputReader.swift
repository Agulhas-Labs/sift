//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads a wrapped command's output while a thread of its own waits for the command to exit, and stops reading once the command has exited and the output has gone quiet.
///
/// Reading to the pipe's end alone waits on every process holding its write end, including one the command left running that outlives it. While the command runs nothing is different: every byte is read as it arrives. Once it has exited, what it wrote is already in the pipe and is read in full; only then does ``RunOutputPatience`` bound the wait for the end.
struct RunOutputReader {
    let patience: RunOutputPatience

    /// Reads `descriptor`, handing each chunk to `consume`, while `exit` — the one wait for the command, which must block until it exits and answer its code — runs on a thread of its own.
    ///
    /// The descriptor is left open: closing it is the caller's.
    func read(_ descriptor: Int32, waitingFor exit: @escaping @Sendable () -> Int32, consume: (Data) -> Void) -> Ending {
        var wake: [Int32] = [-1, -1]
        guard pipe(&wake) == 0 else {
            readToEnd(descriptor, consume: consume)
            return Ending(exitCode: exit(), heldOpen: false)
        }
        _ = fcntl(wake[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(wake[1], F_SETFD, FD_CLOEXEC)
        defer { close(wake[0]) }
        let record = ExitRecord()
        let signal = wake[1]
        // The wake byte is written and its end closed before the code is recorded, so the wait below cannot return —
        // and the read end above be closed — while this thread can still write into it.
        Thread.detachNewThread {
            let code = exit()
            var byte: UInt8 = 1
            _ = Darwin.write(signal, &byte, 1)
            close(signal)
            record.record(code)
        }
        let heldOpen = readUntilQuiet(descriptor, wake: wake[0], consume: consume)
        return Ending(exitCode: record.wait(), heldOpen: heldOpen)
    }

    /// Reads until the end, or until the command has exited and the output has stayed quiet for the grace or run past the cap; answers whether it stopped for either of those.
    private func readUntilQuiet(_ descriptor: Int32, wake: Int32, consume: (Data) -> Void) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var watched = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        var exitedAt: Date?
        var lastHeard = patience.now()
        while true {
            var timeout: Int32 = -1
            if let exitedAt {
                let now = patience.now()
                let cap = exitedAt.addingTimeInterval(patience.cap)
                if now >= cap {
                    return true
                }
                timeout = Self.milliseconds(from: now, to: min(lastHeard.addingTimeInterval(patience.grace), cap))
            }
            let ready = poll(&watched, nfds_t(exitedAt == nil ? 2 : 1), timeout)
            if ready < 0 {
                guard errno == EINTR else {
                    readToEnd(descriptor, consume: consume)
                    return false
                }
                continue
            }
            if ready == 0 {
                // Only a run whose command has exited waits with a timeout, so this is the output gone quiet.
                if patience.now() >= lastHeard.addingTimeInterval(patience.grace) {
                    return true
                }
                continue
            }
            if exitedAt == nil, watched[1].revents != 0 {
                exitedAt = patience.now()
                lastHeard = exitedAt ?? lastHeard
            }
            guard watched[0].revents != 0 else {
                continue
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return false
            }
            if count < 0 {
                guard errno == EINTR || errno == EAGAIN else {
                    return false
                }
                continue
            }
            consume(Data(buffer[0 ..< count]))
            lastHeard = patience.now()
        }
    }

    /// Reads to the end with no regard to the command's exit, the way every run read before it could tell.
    private func readToEnd(_ descriptor: Int32, consume: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                consume(Data(buffer[0 ..< count]))
            } else if count == 0 || errno != EINTR {
                return
            }
        }
    }

    /// The wait from `now` to `deadline` as `poll` takes it: whole milliseconds, rounded up, never negative.
    private static func milliseconds(from now: Date, to deadline: Date) -> Int32 {
        let interval = deadline.timeIntervalSince(now) * 1000
        return Int32(min(max(0, interval.rounded(.up)), Double(Int32.max)))
    }
}

extension RunOutputReader {
    /// What reading came to: the command's exit code, and whether its output was still held open when reading stopped.
    struct Ending {
        let exitCode: Int32
        let heldOpen: Bool
    }

    /// The command's exit code, recorded by the thread that waited for it and handed to the one reader that asks.
    private final class ExitRecord: @unchecked Sendable {
        private let gate = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var code: Int32 = 0

        func record(_ code: Int32) {
            gate.withLock { self.code = code }
            done.signal()
        }

        func wait() -> Int32 {
            done.wait()
            return gate.withLock { code }
        }
    }
}
