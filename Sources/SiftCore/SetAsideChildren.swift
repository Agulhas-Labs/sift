//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation

/// Every process a `run --without` starts while the tree is set aside — git's plumbing and the test command — each in a session of its own, and each announced to the watcher and written into the store before it runs a single instruction.
///
/// **No restore may begin while anything that could write the tree on the run's behalf is still alive,** and nothing a process starts dies with it: an `update-index` still to take the lock, a smudge filter still writing, a test that left a writer running in the background all outlive a run killed outright. So each child is started suspended in a session of its own, its session is written to the watcher and to the store, and only then is it let go. Everything it starts inherits that session unless it deliberately leaves one, which starting a new process group does not do — and a new group is exactly what `Process`, SwiftPM and a test runner each create for their children, which is why a process group would not have held them. Whoever restores — the run itself, its watcher, or a `run --restore` after both are gone — ends every session first and waits for each to be empty.
///
/// **Announced first, because a pid learned afterwards can come too late.** A child that ran for even a moment before the watcher knew of it could be the one left writing; one that is still suspended when its owner dies never runs at all.
///
/// **Written into the store too, because the watcher can die with its run.** A `run --restore` started after both are gone has nobody to ask, so it reads the sessions from `.sift/set-aside/sessions` — each with the time its leader started, so a pid reused by somebody else's process is never taken for one of these.
///
/// **What it cannot reach**: a process that calls `setsid` for itself, or one started on the command's behalf by a service manager — a simulator, `launchd`, the test runner `xcodebuild` asks to launch its tests — is no part of the command's process tree. Anything such a process writes into a recorded path before the restore is kept beside it like any other write; anything it writes after the restore lands in the restored tree.
public final class SetAsideChildren: @unchecked Sendable {
    private let gate = NSLock()
    private var sessions: [pid_t: UInt64] = [:]
    /// The sessions a caught signal is passed on to: the test runs, never git's plumbing, which a restore depends on finishing.
    private var forwarded: Set<pid_t> = []
    private var watcher: SetAsideGuardian.Handle?
    private var ledger: URL?

    public init() {}
}

public extension SetAsideChildren {
    /// One session a child was started in: the leader's pid, which is also the session's id, and when the leader was started — which no process that later reuses the pid can share.
    struct Session: Sendable, Hashable {
        public let pid: pid_t
        /// Microseconds since 1970, from the kernel; `0` where it could not be read, which makes the pid the only check.
        public let started: UInt64

        public init(pid: pid_t, started: UInt64) {
            self.pid = pid
            self.started = started
        }
    }

    /// Hands every session from here on to `watcher`, and any already running.
    func attach(_ watcher: SetAsideGuardian.Handle) {
        gate.withLock {
            self.watcher = watcher
            for (pid, started) in sessions {
                watcher.announce(Session(pid: pid, started: started))
            }
        }
    }

    /// Writes every session from here on into `ledger`, and any already running — or, given `nil`, stops writing, once the store it is in is about to go.
    func record(into ledger: URL?) {
        gate.withLock {
            self.ledger = ledger
            if let ledger {
                Self.append(sessions.map { Session(pid: $0.key, started: $0.value) }, to: ledger)
            }
        }
    }

    /// Sends `number` to every process in every test run still running — how a signal the run caught reaches a command that no longer shares its terminal.
    ///
    /// Never to git's plumbing: a signal passed on to the `update-index` of a restore in progress would be what made the restore fail.
    func signalAll(_ number: Int32) {
        let targets = gate.withLock { forwarded.compactMap { pid in sessions[pid].map { Session(pid: pid, started: $0) } } }
        for session in targets {
            for member in Self.members(of: session) {
                kill(member, number)
            }
        }
    }

    /// Ends every session still running and forgets them all — after giving them `patience` to end on their own, for a command a signal was just passed on to.
    func endAll(patience: TimeInterval = 0) {
        let all = gate.withLock { sessions.map { Session(pid: $0.key, started: $0.value) } }
        _ = Self.waitUntilEmpty({ all.flatMap { Self.members(of: $0) } }, for: patience)
        Self.end(sessions: all)
        for session in all {
            forget(session.pid)
        }
    }

    /// Ends whatever a finished child left running in its session, and forgets the session; answers how many processes that was.
    @discardableResult
    func settle(_ pid: pid_t) -> Int {
        guard let started = gate.withLock({ sessions[pid] }) else {
            return 0
        }
        let session = Session(pid: pid, started: started)
        let left = Self.members(of: session).count
        if left > 0 {
            Self.end(sessions: [session])
        }
        forget(pid)
        return left
    }

    /// Forgets a session without ending anything in it — for a child whose leftovers are the caller's own business, as the second run's are once the tree is back.
    func forget(_ pid: pid_t) {
        gate.withLock {
            forwarded.remove(pid)
            if sessions.removeValue(forKey: pid) != nil {
                watcher?.retire(pid)
            }
        }
    }
}

public extension SetAsideChildren {
    /// Every live process in `session`, less this one.
    ///
    /// A leader alive under another start time is somebody else's process holding a reused pid, and its session is none of this run's; a member started before the leader cannot have been started by it.
    static func members(of session: Session) -> [pid_t] {
        guard session.pid > 0 else {
            return []
        }
        if session.started != 0, let leader = KernelProcess.startMicroseconds(of: session.pid), leader != session.started {
            return []
        }
        let needed = Int(proc_listallpids(nil, 0))
        guard needed > 0 else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: needed + 256)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        let own = getpid()
        return pids.prefix(max(0, Int(count))).filter { pid in
            guard pid > 0, pid != own, getsid(pid) == session.pid else {
                return false
            }
            guard session.started != 0 else {
                return true
            }
            return KernelProcess.startMicroseconds(of: pid).map { $0 >= session.started } ?? false
        }
    }

    /// Ends every process in `sessions`: `SIGTERM` first, so a git holding the index lock can let go of it, then `SIGKILL` for whatever is left — and waits for them to be gone; answers how many processes there were.
    ///
    /// Returns once every session is empty, or once what is left has had `SIGKILL` pending for a while: a process with `SIGKILL` pending never runs another instruction of its own, so it cannot start a write, whatever it is still doing in the kernel.
    @discardableResult
    static func end(sessions: [Session], grace: TimeInterval = 3, settle: TimeInterval = 10) -> Int {
        func remaining() -> [pid_t] {
            sessions.flatMap { members(of: $0) }
        }
        var left = remaining()
        let found = left.count
        guard !left.isEmpty else {
            return 0
        }
        for member in left {
            kill(member, SIGTERM)
        }
        left = waitUntilEmpty(remaining, for: grace)
        for member in left {
            kill(member, SIGKILL)
        }
        // A process can fork between one listing and the next kill, so the kill is repeated until nothing is found.
        let deadline = Date().addingTimeInterval(settle)
        while !left.isEmpty, Date() < deadline {
            for member in left {
                kill(member, SIGKILL)
            }
            usleep(20000)
            left = remaining()
        }
        return found
    }

    /// The sessions written into `ledger`, in the order they were started; an unreadable or missing ledger reads as none.
    static func sessions(in ledger: URL) -> [Session] {
        guard let text = try? String(contentsOf: ledger, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = pid_t(fields[0]), let started = UInt64(fields[1]) else {
                return nil
            }
            return Session(pid: pid, started: started)
        }
    }

    private static func waitUntilEmpty(_ remaining: () -> [pid_t], for interval: TimeInterval) -> [pid_t] {
        let deadline = Date().addingTimeInterval(interval)
        var left = remaining()
        while !left.isEmpty, Date() < deadline {
            usleep(20000)
            left = remaining()
        }
        return left
    }

    /// Appends one line per session.
    ///
    /// Not flushed to disk: what it guards against is a process dying, and a machine going down takes every one of these processes with it.
    private static func append(_ sessions: [Session], to ledger: URL) {
        guard !sessions.isEmpty else {
            return
        }
        let descriptor = open(ledger.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return
        }
        defer { close(descriptor) }
        let bytes = Array(sessions.map { "\($0.pid) \($0.started)\n" }.joined().utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}

public extension SetAsideChildren {
    /// Where a child's three standard streams go.
    struct Streams {
        public let input: Int32
        public let output: Int32
        public let error: Int32

        public init(input: Int32, output: Int32, error: Int32) {
            self.input = input
            self.output = output
            self.error = error
        }
    }

    /// Starts `executable` in a session of its own, with `streams` as its standard streams and nothing else inherited, announces the session and writes it down, and only then lets it run; returns its pid, which is also its session's id.
    ///
    /// A command started as forwarding signals is one a signal the run catches is passed on to.
    func spawn(
        _ executable: String,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String],
        streams: Streams,
        forwardingSignals: Bool = false
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, streams.input, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, streams.output, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, streams.error, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // This process ignores the signals that end a run while one is in progress, and an ignored signal
        // survives exec: the child starts from the defaults, with nothing blocked.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = [executable] + arguments
        let variables = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = Self.withCStrings(argv) { argvPointers in
            Self.withCStrings(variables) { environmentPointers in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointers, environmentPointers)
            }
        }
        guard result == 0 else {
            throw SetAsideError.store("could not start \(executable): \(String(cString: strerror(result)))")
        }
        // Read while it is still suspended, so the time is the leader's and the pid cannot yet have been reused.
        let session = Session(pid: pid, started: KernelProcess.startMicroseconds(of: pid) ?? 0)
        gate.withLock {
            sessions[pid] = session.started
            if forwardingSignals {
                forwarded.insert(pid)
            }
            if let ledger {
                Self.append([session], to: ledger)
            }
            watcher?.announce(session)
        }
        kill(pid, SIGCONT)
        return pid
    }

    /// Waits for a child to exit and answers its exit code — `128 + signal` for one a signal ended, as a shell reports it.
    static func exitCode(waitingFor pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else {
                return 127
            }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}

extension SetAsideChildren {
    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return body(pointers)
    }
}
