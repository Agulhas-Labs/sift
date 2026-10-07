//
// Copyright © Agulhas Labs
//

import Foundation

/// A second process that deletes a sharded run's simulators when the run itself cannot: it was killed, it crashed, or its whole process tree was taken down at once.
///
/// **No handler inside a process survives `SIGKILL`, and a crash runs none at all,** so a promise to delete every device on every exit path needs something outside the process. This is it, and it is ``WatcherProcess`` underneath — the same detached, session-of-its-own, pipe-watching mechanism the set-aside guardian is built on, with a smaller protocol over it: the watcher writes one byte to say it is watching, the owner writes one to let it go, and end-of-file without that byte is the owner having died.
///
/// **It ends the run's test processes before it deletes anything.** An `xcodebuild` still driving a device that is being deleted is the case this exists to rule out, so the owner records each shard's session in a file beside the run's record (``ShardGuardian/sessionsFile(for:)``) and the watcher ends every session in it — `SIGTERM`, then `SIGKILL`, waiting for them to empty — before the first `simctl delete`.
///
/// **It deletes by udid, from the run's own record, and removes the record only when every delete succeeded.** A device it could not delete keeps the record on disk, where the next run's sweep finds it; nothing here ever deletes a device by name or a device this run did not create.
///
/// **It names itself in the record.** The watcher's pid and start time follow its first byte down the handshake pipe, and the owner writes them into the record — so a later run reading that record can tell a run somebody is still cleaning up from one that nobody is.
public struct ShardGuardian: Sendable {
    private init() {}

    /// The byte a watcher writes once it is watching, followed by the pid and start time that name it.
    static let watching = UInt8(ascii: "w")
    /// The byte an owner writes to let its watcher go.
    static let released = UInt8(ascii: "r")
    /// A byte the watcher ignores, written only to learn whether anybody is still reading.
    static let probe = UInt8(ascii: "p")
}

public extension ShardGuardian {
    /// The owner's end of a running watcher.
    ///
    /// **Every write says whether the watcher was still reading.** The pipe fails a write once nobody holds its other end, so a watcher that died — killed by hand, or taken down with a process tree the run was not part of — is learned of at the next byte, rather than never.
    final class Handle: @unchecked Sendable {
        /// The watcher this handle speaks to, as the run's record names it.
        public let watcher: ShardLedger.Identity

        private let gate = NSLock()
        private var descriptor: Int32
        private var lost = false

        init(descriptor: Int32, watcher: ShardLedger.Identity) {
            self.descriptor = descriptor
            self.watcher = watcher
        }

        /// Tells the watcher the devices are gone, which it leaves on; dropping the handle without this reads to the watcher as the owner dying.
        ///
        /// Answers whether the watcher was still there to be told — `false` means it died at some point before, while devices were on the disk with nothing to delete them after a kill.
        @discardableResult
        public func release() -> Bool {
            gate.withLock {
                guard descriptor >= 0 else {
                    return !lost
                }
                var byte = ShardGuardian.released
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
            gate.withLock {
                guard descriptor >= 0 else {
                    return !lost
                }
                var byte = ShardGuardian.probe
                if write(descriptor, &byte, 1) != 1 {
                    lost = true
                }
                return !lost
            }
        }
    }

    /// Starts `executable` as the watcher for `runID`, records it in that run's record, and returns once it has confirmed it is watching.
    ///
    /// Throws ``ShardError/watcher(_:)`` when it cannot be started or does not confirm within `timeout` — and the caller must then create no device, since the promise to delete them after a kill is the watcher's to keep.
    static func arm(executable: URL, runID: String, repositoryRoot: URL, timeout: TimeInterval = 20) throws -> Handle {
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
            // `$0` is the executable, `$1` the run, `$2` the directory: each passed as an argument, never
            // spliced into the script, so no path can change what the script says.
            script: "cd -- \"$2\" || exit 1; \"$0\" test --guard-shards \"$1\" & exit 0",
            arguments: [executable.path, runID, repositoryRoot.path],
            stdout: handshake.write,
            liveness: liveness.read
        )
        close(handshake.write)
        close(liveness.read)
        guard spawned == 0 else {
            close(handshake.read)
            close(liveness.write)
            throw ShardError.watcher("/bin/sh could not be started: \(String(cString: strerror(spawned)))")
        }
        let confirmed = confirmation(on: handshake.read, timeout: timeout)
        close(handshake.read)
        var status: Int32 = 0
        waitpid(shell, &status, 0)
        guard let confirmed else {
            close(liveness.write)
            throw ShardError.watcher("it did not confirm it was watching within \(Int(timeout)) seconds")
        }
        let handle = Handle(descriptor: liveness.write, watcher: confirmed)
        do {
            try name(confirmed, runID: runID, repositoryRoot: repositoryRoot)
        } catch {
            // A watcher nobody could write down is a watcher the next run cannot account for: let it go, and
            // leave the caller to create nothing.
            handle.release()
            throw error
        }
        return handle
    }

    /// The watcher's side, run by `sift test --guard-shards <runid>`: confirm, wait for the owner to let go or to die, and clean the run up after a death.
    ///
    /// Returns the exit status, which nobody reads — the owner is gone by the time it matters. What anyone can read is the record: gone means every device went with it, and still there means a device is still on the disk for the next run's sweep to find.
    static func watch(
        runID: String,
        repositoryRoot: URL,
        run: ShardDevices.Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.deleteDeadline) }
    ) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        confirm(ShardLedger.Identity.current())
        // Ends at the release byte, at end of file, or at a read that failed: the last two are the owner gone.
        var last: UInt8?
        while let tag = WatcherProcess.readByte() {
            guard tag == released else {
                continue
            }
            last = tag
            break
        }
        return sweep(
            read: last,
            runID: runID,
            repositoryRoot: repositoryRoot,
            run: run,
            endSessions: { SetAsideChildren.end(sessions: $0) }
        )
    }

    /// Where the owner records each shard's test process, for the watcher to end before it deletes a device out from under one.
    static func sessionsFile(for ledger: ShardLedger) -> URL {
        sessionsFile(inRunDirectory: ledger.directory)
    }
}

extension ShardGuardian {
    /// What the watcher does with the last byte it read: nothing at all on a release, and on a death the sessions before the devices.
    ///
    /// The order is the whole point — a test process still driving a device that is being deleted is what this rules out — so the ender is called before the first `simctl`, and a test can watch that from the runner it injects.
    static func sweep(
        read byte: UInt8?,
        runID: String,
        repositoryRoot: URL,
        run: ShardDevices.Run,
        endSessions: ([SetAsideChildren.Session]) -> Void
    ) -> Int32 {
        guard byte != released else {
            return 0
        }
        endSessions(SetAsideChildren.sessions(in: sessionsFile(inRunDirectory: ShardLedger.directory(in: repositoryRoot, runID: runID))))
        switch ShardLedger.read(repositoryRoot: repositoryRoot, runID: runID) {
        case let .ledger(ledger):
            let cleanup = ShardDevices.deleteAll(in: ledger, run: run)
            return cleanup.deletions.contains { $0.failure != nil } ? 1 : 0
        case .missing:
            // The record is gone, which is what a run that deleted its own devices leaves behind.
            return 0
        case .unreadable:
            // A record that cannot be read names no udid; its devices are left to the next run's sweep, which
            // finds them by the name they were created under.
            return 1
        }
    }

    /// The same file, named from the run's directory alone, which the watcher has whether or not the record in it can be read.
    static func sessionsFile(inRunDirectory directory: URL) -> URL {
        directory.appendingPathComponent(sessionsFileName)
    }

    private static var sessionsFileName: String {
        "sessions"
    }

    /// Says on standard output that this process is watching and which process it is, then gives the streams up: a caller waiting for the run's output to end is never kept waiting by the watcher.
    private static func confirm(_ identity: ShardLedger.Identity) {
        let message = [watching] + bytes(of: UInt32(bitPattern: identity.pid)) + bytes(of: identity.startMicroseconds)
        _ = message.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            close(null)
        }
    }

    /// The watcher that confirmed within `timeout`, or `nil` where none did.
    private static func confirmation(on descriptor: Int32, timeout: TimeInterval) -> ShardLedger.Identity? {
        guard WatcherProcess.awaitByte(on: descriptor, timeout: timeout) == watching,
              let pid = awaitInteger(UInt32.self, on: descriptor, timeout: timeout),
              let started = awaitInteger(UInt64.self, on: descriptor, timeout: timeout)
        else {
            return nil
        }
        return ShardLedger.Identity(pid: Int32(bitPattern: pid), startMicroseconds: started)
    }

    /// Writes the watcher into the run's record, where a later run reads whether anybody is still going to clean this one up.
    private static func name(_ identity: ShardLedger.Identity, runID: String, repositoryRoot: URL) throws {
        guard case var .ledger(ledger) = ShardLedger.read(repositoryRoot: repositoryRoot, runID: runID) else {
            throw ShardError.ledger("the record for run \(runID) could not be read, so the watcher that was started for it cannot be named in it.")
        }
        try ledger.recordWatcher(identity)
    }

    /// A big-endian integer of `type`'s width, read a byte at a time so one deadline covers the whole of it.
    private static func awaitInteger<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type, on descriptor: Int32, timeout: TimeInterval) -> Value? {
        var value: Value = 0
        for _ in 0 ..< Value.bitWidth / 8 {
            guard let byte = WatcherProcess.awaitByte(on: descriptor, timeout: timeout) else {
                return nil
            }
            value = value << 8 | Value(byte)
        }
        return value
    }

    private static func bytes(of value: some FixedWidthInteger) -> [UInt8] {
        (0 ..< value.bitWidth / 8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// A pipe for a watcher, with the failure a sharded run's reader is given for one that cannot be started.
    private static func pipe() throws -> (read: Int32, write: Int32) {
        do {
            return try WatcherProcess.elevatedPipe()
        } catch let WatcherProcess.Failure.unavailable(reason) {
            throw ShardError.watcher(reason)
        }
    }
}
