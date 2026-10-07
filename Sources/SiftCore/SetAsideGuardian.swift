//
// Copyright © Agulhas Labs
//

import Foundation

/// A second process that puts a set-aside tree back when the one that set it aside cannot: it was killed, it crashed, or its whole process tree was taken down at once.
///
/// **No handler inside a process survives `SIGKILL`, and a crash runs none at all,** so a promise to restore on every exit path needs something outside the process. This is it: a copy of `sift` started before the tree is touched, whose only job is to wait for its owner to go away and, if the record is still there when it does, restore from it.
///
/// **It learns of the death from a pipe, not from a process id.** The owner holds the only write end, opened close-on-exec so no command it launches inherits it; when the owner dies, however it dies, the kernel closes that end and the watcher's read returns end-of-file. There is no pid to be reused and no polling. When the owner puts the tree back itself it writes one byte instead, and the watcher leaves without touching anything.
///
/// **It is started out of the owner's reach,** by ``WatcherProcess``, which is that plumbing on its own — the pipe, the detached spawn and the confirmation — and serves every guardian that makes this promise. Through `/bin/sh … &`, so it is re-parented away and is no descendant of the run — a tool that tears down a process tree to stop a hung command takes the run and leaves the watcher — and in a session of its own, so the terminal's `SIGINT` and `SIGHUP` go to the run and never to it. It holds nothing of the caller's: its standard streams are `/dev/null` once it has confirmed it is watching, so a caller waiting for the run's output to end is never kept waiting by it.
///
/// **It restores only the record it was started for,** checked by id under the set-aside lock, so a watcher that outlives its owner can never restore a later run's record.
///
/// **It takes the lock before it does anything else, then ends what its owner started, and only then restores.** The owner writes the session of every child it starts down the same pipe before the child runs (``SetAsideChildren``); when the owner dies the watcher takes the set-aside lock — so no `run --restore` can put the tree back while those sessions are still alive — then ends every one of them, with every session the owner wrote into the store beside them — `SIGTERM`, then `SIGKILL` — and waits for them to empty. A git still writing the index, a smudge filter still producing a file, a test's background writer: none of them can go on writing into a tree the watcher has already put back.
///
/// **It holds `.sift/set-aside.watch` for as long as it lives,** so that between its owner dying and its taking the lock — the one moment the lock is free and the record still there — a `sift run` waits for it rather than telling the reader nobody is going to put the tree back.
public struct SetAsideGuardian: Sendable {
    private init() {}

    /// The byte a watcher writes once it is watching.
    static let watching = UInt8(ascii: "w")
    /// The byte an owner writes to let its watcher go.
    static let released = UInt8(ascii: "r")
    /// The byte that heads a session the watcher must end before it restores, followed by its id and its leader's start time.
    static let started = UInt8(ascii: "c")
    /// The byte that heads a session the owner has ended itself, followed by its id.
    static let ended = UInt8(ascii: "d")
    /// A byte the watcher ignores, written only to learn whether anybody is still reading.
    static let probe = UInt8(ascii: "p")
}

public extension SetAsideGuardian {
    /// The owner's end of a running watcher.
    ///
    /// **Every write says whether the watcher was still reading.** The pipe fails a write once nobody holds its other end, so a watcher that died — killed by hand, or taken down with a process tree the run was not part of — is learned of at the next byte, rather than never.
    final class Handle: @unchecked Sendable {
        private let gate = NSLock()
        private var descriptor: Int32
        private var lost = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Tells the watcher the tree is back, which it leaves on; dropping the handle without this reads to the watcher as the owner dying.
        ///
        /// Answers whether the watcher was still there to be told — `false` means it died at some point before, while the changes were out of the tree with nothing to put them back after a kill.
        @discardableResult
        public func release() -> Bool {
            gate.withLock {
                guard descriptor >= 0 else {
                    return !lost
                }
                var byte = SetAsideGuardian.released
                if write(descriptor, &byte, 1) != 1 {
                    lost = true
                }
                close(descriptor)
                descriptor = -1
                return !lost
            }
        }

        /// Whether the watcher is still reading: one byte it ignores, which fails to write once it is gone.
        public func isWatching() -> Bool {
            send([SetAsideGuardian.probe])
            return gate.withLock { !lost }
        }

        /// Tells the watcher of a session to end before it restores.
        ///
        /// Thirteen bytes, which a pipe writes whole.
        func announce(_ session: SetAsideChildren.Session) {
            send([SetAsideGuardian.started] + Self.bytes(of: UInt32(bitPattern: session.pid)) + Self.bytes(of: session.started))
        }

        /// Tells the watcher a session is over, so it never signals a number that could by then name somebody else's.
        func retire(_ session: pid_t) {
            send([SetAsideGuardian.ended] + Self.bytes(of: UInt32(bitPattern: session)))
        }

        private func send(_ message: [UInt8]) {
            gate.withLock {
                guard descriptor >= 0 else {
                    return
                }
                if message.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) != message.count {
                    lost = true
                }
            }
        }

        private static func bytes(of value: some FixedWidthInteger) -> [UInt8] {
            (0 ..< value.bitWidth / 8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    /// Starts `executable` as the watcher for `record`, and returns once it has confirmed it is watching.
    ///
    /// Throws ``SetAsideError/guardUnavailable(_:)`` when it cannot be started or does not confirm within `timeout` — and the caller must then set nothing aside, since the promise to restore after a kill is the watcher's to keep.
    static func arm(executable: URL, record: SetAsideRecord, repositoryRoot: URL, timeout: TimeInterval = 20) throws -> Handle {
        let liveness = try pipe()
        let handshake: (read: Int32, write: Int32)
        do {
            handshake = try pipe()
        } catch {
            close(liveness.read)
            close(liveness.write)
            throw error
        }
        // Writing to a watcher that has gone must fail with an error, not end the owner with SIGPIPE.
        _ = fcntl(liveness.write, F_SETNOSIGPIPE, 1)
        let (spawned, shell) = WatcherProcess.spawnDetached(
            // `$0` is the executable, `$1` the record, `$2` the directory: each passed as an argument, never
            // spliced into the script, so no path can change what the script says.
            script: "cd -- \"$2\" || exit 1; \"$0\" run --guard-set-aside \"$1\" & exit 0",
            arguments: [executable.path, record.id, repositoryRoot.path],
            stdout: handshake.write,
            liveness: liveness.read
        )
        close(handshake.write)
        close(liveness.read)
        guard spawned == 0 else {
            close(handshake.read)
            close(liveness.write)
            throw SetAsideError.guardUnavailable("/bin/sh could not be started: \(String(cString: strerror(spawned)))")
        }
        let confirmed = WatcherProcess.awaitByte(on: handshake.read, timeout: timeout) == watching
        close(handshake.read)
        var status: Int32 = 0
        waitpid(shell, &status, 0)
        guard confirmed else {
            close(liveness.write)
            throw SetAsideError.guardUnavailable("it did not confirm it was watching within \(Int(timeout)) seconds")
        }
        return Handle(descriptor: liveness.write)
    }

    /// The watcher's side, run by `sift run --guard-set-aside <id>`: confirm, wait for the owner to let go or to die, and restore after a death.
    ///
    /// Returns the exit status, which nobody reads — the owner is gone by the time it matters. What anyone can read is the record: gone means the tree is back, and still there means `sift run` will refuse and name `sift run --restore`.
    static func watch(recordID: String, repositoryRoot: URL) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let store = SetAsideStore(repositoryRoot: repositoryRoot)
        // Taken before it confirms, and kept until the process exits: a watcher that cannot say it is alive
        // does not start, and the run then sets nothing aside.
        guard let alive = SetAsideLock.watch(for: store) else {
            return 1
        }
        defer { withExtendedLifetime(alive) {} }
        var confirmation = watching
        _ = write(STDOUT_FILENO, &confirmation, 1)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            close(null)
        }
        var announced: [pid_t: UInt64] = [:]
        // Ends at end of file, or a read that failed: either way the owner is gone.
        reading: while let tag = WatcherProcess.readByte() {
            switch tag {
            case released:
                return 0
            case started:
                guard let pid = readInteger(UInt32.self), let started = readInteger(UInt64.self) else {
                    break reading
                }
                announced[pid_t(bitPattern: pid)] = started
            case ended:
                guard let pid = readInteger(UInt32.self) else {
                    break reading
                }
                announced[pid_t(bitPattern: pid)] = nil
            default:
                continue
            }
        }
        var sessions = announced.map { SetAsideChildren.Session(pid: $0.key, started: $0.value) }
        // The lock before anything else: while it is held no `run --restore` can put the tree back under what the
        // owner left running, and it is free the moment the owner died, however it died.
        guard let lock = try? SetAsideLock.take(for: store, as: .watcher, waiting: true) else {
            SetAsideChildren.end(sessions: sessions)
            return 1
        }
        defer { lock.release() }
        let record = try? store.record()
        if let record, record.id == recordID {
            sessions += SetAsideChildren.sessions(in: store.sessionsURL)
        }
        SetAsideChildren.end(sessions: Array(Set(sessions)))
        guard let record, record.id == recordID else {
            return 0
        }
        do {
            _ = try SetAside(store: store).restore(record)
            return 0
        } catch {
            return 1
        }
    }
}

extension SetAsideGuardian {
    /// A pipe for a watcher, with the failure a `sift run --without` reader is given for one that cannot be started.
    private static func pipe() throws -> (read: Int32, write: Int32) {
        do {
            return try WatcherProcess.elevatedPipe()
        } catch let WatcherProcess.Failure.unavailable(reason) {
            throw SetAsideError.guardUnavailable(reason)
        }
    }

    /// A big-endian integer of `type`'s width, following its tag.
    private static func readInteger<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type) -> Value? {
        var value: Value = 0
        for _ in 0 ..< Value.bitWidth / 8 {
            guard let byte = WatcherProcess.readByte() else {
                return nil
            }
            value = value << 8 | Value(byte)
        }
        return value
    }
}
