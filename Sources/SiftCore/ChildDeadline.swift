//
// Copyright © Agulhas Labs
//

import Foundation

/// The bound on a child process this tool waits for: when it overruns, the child and every process still in its process group are ended, the child is reaped, and the caller stops reading its streams.
///
/// **Why a git child needs one.** A repository whose `.git/config` has `include.path` naming a FIFO makes `git rev-parse` block in `open(2)` for good, and every hook runs a git before it answers. Without a bound the hook hangs until its own timeout kills it, and the git it spawned is orphaned still blocked. The answer a bounded read gives is the one an unreadable repository already gets: a failed git call, which every caller treats as "no repository".
///
/// **The group, because git starts children of its own** — a `!` alias's shell, a `core.fsmonitor` hook, a clean filter, a textconv — and a descendant holds git's stdout and stderr for as long as it lives. `Process` starts its child as the leader of a process group of its own, and a descendant stays in that group unless it leaves deliberately, so signalling the group reaches all of them.
///
/// **What it cannot end**: a descendant that has left the group (a daemon that calls `setsid`, a job a shell with job control started) is not signalled. The call still returns at the bound, because reading stops there whatever holds the pipes; that descendant is left running.
public struct ChildDeadline: Sendable {
    private init() {}

    /// How long a git read may run: well under the 8 seconds a hook is given in all, so that a hook which asks git more than once still answers inside them.
    public static let git: TimeInterval = 2

    /// How long a git read whose answer grows with the repository or with its input may run (a file listing, a status, a diff, a history walk, blobs, a batch of paths): long enough that a large repository is not cut off, still finite so that a hook is never left on a git that cannot finish.
    public static let gitBulk: TimeInterval = 60

    /// How long a child that was sent `SIGTERM` has to leave before it is sent `SIGKILL`.
    static let grace: TimeInterval = 0.25

    private static let pollInterval: useconds_t = 5000

    /// Ends `process` and every process still in its group, and waits until `process` has been reaped: `SIGTERM`, a short grace, then `SIGKILL` for whatever is left; answers whether `process` was still running when it began.
    ///
    /// **A child that has already exited is not reported as ended**, so a child that finishes at the deadline is read as having answered. Its group is still signalled: a descendant may hold its streams after it is gone. The group id cannot be reused while any process is still in the group, nor the leader's pid while the leader is unreaped. `Process.terminate` is not used: it raises for a process that has already exited, and signals the child alone.
    @discardableResult
    public static func stop(_ process: Process) -> Bool {
        let group = process.processIdentifier
        // A process that never launched has pid 0, and `kill(-0, …)` would signal this process's own group.
        guard group > 1 else { return false }
        let wasRunning = process.isRunning
        kill(-group, SIGTERM)
        let limit = Date() + grace
        while Date() < limit, process.isRunning || kill(-group, 0) == 0 {
            usleep(pollInterval)
        }
        if process.isRunning || kill(-group, 0) == 0 {
            kill(-group, SIGKILL)
        }
        if wasRunning {
            process.waitUntilExit()
        }
        return wasRunning
    }
}

public extension ChildDeadline {
    /// A deadline running beside a child whose streams the caller reads: on expiry it ends the child with ``ChildDeadline/stop(_:)``.
    ///
    /// Armed after `Process.run`. Ended by ``finish()`` once the caller has its answer, or by ``expire()`` when the caller stopped reading first; the expiry runs once, whichever of the caller and the watching thread reaches it first.
    final class Watch: @unchecked Sendable {
        private let process: Process
        private let limit: TimeInterval
        private let done = DispatchSemaphore(value: 0)
        private let condition = NSCondition()
        private var state = State.watching
        private var ended = false
        private var armedUntil = DispatchTime.distantFuture

        public init(_ process: Process, within limit: TimeInterval) {
            self.process = process
            self.limit = limit
        }

        /// When the deadline passes: `limit` after ``arm()``, and never before it is armed.
        public var deadline: DispatchTime {
            condition.withLock { armedUntil }
        }

        /// Whether the deadline ended a child that was still running; an expiry in progress is waited for, so this never answers before it knows.
        public var timedOut: Bool {
            condition.lock()
            defer { condition.unlock() }
            while state == .expiring {
                condition.wait()
            }
            return ended
        }

        public func arm() {
            let until = DispatchTime.now() + limit
            condition.withLock { armedUntil = until }
            let thread = Thread { [self] in
                guard done.wait(timeout: until) == .timedOut else { return }
                expire()
            }
            thread.name = "sift.child-deadline"
            thread.start()
        }

        /// Ends the child and its group now and waits until the child is reaped; a call while another is ending it waits for that one, and a call after ``finish()`` does nothing.
        public func expire() {
            condition.lock()
            switch state {
            case .watching:
                state = .expiring
                condition.unlock()
            case .expiring:
                while state == .expiring {
                    condition.wait()
                }
                condition.unlock()
                return
            case .finished, .settled:
                condition.unlock()
                return
            }
            let wasRunning = ChildDeadline.stop(process)
            condition.withLock {
                ended = wasRunning
                state = .settled
                condition.broadcast()
            }
            done.signal()
        }

        /// The caller has its answer, and the watching thread ends without touching the child.
        ///
        /// Never blocks, so a termination handler may call it.
        public func finish() {
            condition.withLock {
                if state == .watching {
                    state = .finished
                }
            }
            done.signal()
        }

        /// The child's stdout and stderr, each read to its end, and its exit, awaited on `exited` (which its termination handler signals), all inside the deadline; `nil` where the deadline came first.
        ///
        /// **Reading stops at the deadline whatever holds the pipes**: a descendant that inherited them and left the child's group would otherwise keep the call open for as long as it lives. The child and its group are ended at that point, and the watch is finished either way.
        public func collect(stdout: Pipe, stderr: Pipe, exited: DispatchSemaphore) -> (output: Data, failure: Data)? {
            let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr, until: deadline)
            if !streams.complete {
                expire()
            }
            exited.wait()
            finish()
            guard streams.complete, !timedOut else { return nil }
            return (streams.output, streams.failure)
        }
    }
}

private extension ChildDeadline.Watch {
    /// Where a watch is: still watching, finished by its caller, ending the child, or done ending it.
    enum State {
        case watching, finished, expiring, settled
    }
}
