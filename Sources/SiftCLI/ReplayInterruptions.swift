//
// Copyright © Agulhas Labs
//

import Foundation

/// The scratch directories and children of one `audit --replay`, removed and stopped where a Ctrl-C or a `SIGTERM` ends it.
///
/// A run that ends normally removes its scratch where it made it and reaps each child before the launch returns, so nothing here changes that path: it only knows what is live, by exact path and pid, for the one moment a signal would otherwise leave it behind. The signals arrive through sources on a queue of their own, as ``TestInterruptions`` takes them, because the replay holds the main thread for the whole run.
///
/// The cleanup stops the work before it removes what the work writes: it marks the run stopped, so no child is launched and no unit of work begins after that; kills every child and waits for each to exit; waits for the unit of work in flight to end; and only then removes each directory, once, and exits. The main thread writes into the scratch only inside ``working(_:)`` and launches only through ``launch(_:)``, so nothing it starts after the mark can land in what was removed; a unit already running past the five-second wait is the one residue, and it is bounded by the hook's own time budget.
final class ReplayInterruptions: @unchecked Sendable {
    private static let watched: [Int32] = [SIGINT, SIGTERM]

    /// How long the cleanup waits for the unit of work in flight to end before it removes the scratch regardless.
    static let grace: TimeInterval = 5

    private let lock = NSLock()
    /// Held by the main thread across one unit of work, and by the cleanup from the moment that unit ends.
    private let work = NSLock()
    private var stopped = false
    private var directories: Set<URL> = []
    private var children: Set<pid_t> = []
    private var sources: [any DispatchSourceSignal] = []

    /// Turns every watched signal into this cleanup and a non-zero exit, from now until the process ends.
    ///
    /// Each source's handler holds this object, so an armed one lives as long as the process, whether or not its maker keeps it.
    func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard sources.isEmpty else { return }
        let queue = DispatchQueue(label: "sift.replay.signals")
        sources = Self.watched.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { self.interrupted(by: number) }
            source.resume()
            return source
        }
    }

    /// Records `directory` as scratch to remove on a signal, until it is forgotten.
    func track(_ directory: URL) {
        lock.withLock { _ = directories.insert(directory) }
    }

    /// Drops `directory`, which its maker has removed or is about to.
    func forget(_ directory: URL) {
        lock.withLock { _ = directories.remove(directory) }
    }

    /// The child `start` launched and recorded under the cleanup's own lock, or `nil` where it launched none or the run was already stopped and it never ran.
    ///
    /// Under that lock, a child is never alive and unrecorded while the cleanup reads the records.
    func launch(_ start: () -> pid_t?) -> pid_t? {
        lock.withLock {
            guard !stopped, let pid = start() else { return nil }
            children.insert(pid)
            return pid
        }
    }

    /// Drops the child `pid`, which has been reaped or is about to be.
    func forget(child pid: pid_t) {
        lock.withLock { _ = children.remove(pid) }
    }

    /// What `body` returns, run as one unit of work the cleanup waits for, or `nil` without running it where the run is already stopped.
    func admits<Value>(_ body: () throws -> Value) rethrows -> Value? {
        work.lock()
        defer { work.unlock() }
        guard !lock.withLock({ stopped }) else { return nil }
        return try body()
    }

    /// What `body` returns, run as one unit of work the cleanup waits for, the calling thread parked for good instead where the run is stopped before `body` starts or by the time it ends.
    ///
    /// A unit the stop overtook ran against killed children and refused launches, so what it returns is never handed on.
    func working<Value>(_ body: () throws -> Value) rethrows -> Value {
        guard let value = try admits(body), !lock.withLock({ stopped }) else { park() }
        return value
    }

    /// Marks the run stopped, kills every child and waits for each to exit, waits up to ``grace`` for the unit of work in flight, then removes every directory once.
    func stop() {
        let killed = lock.withLock {
            stopped = true
            for pid in children {
                kill(pid, SIGKILL)
            }
            return children
        }
        for pid in killed {
            var info = siginfo_t()
            // Waited on without being reaped, so the launch that owns the child still reaps it; one already reaped answers at once.
            _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        }
        let settled = work.lock(before: Date(timeIntervalSinceNow: Self.grace))
        defer {
            if settled {
                work.unlock()
            }
        }
        for directory in lock.withLock({ directories }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Stops the run and exits with `128 + number`, without returning.
    private func interrupted(by number: Int32) {
        stop()
        _exit(128 + number)
    }

    private func park() -> Never {
        while true {
            sleep(60)
        }
    }
}
