//
// Copyright © Agulhas Labs
//

import Foundation

/// One `run --without`, from the record being written to the second run ending — the one object both the main flow and a signal handler go through, so the two can never change the tree at once.
///
/// **Every step takes one gate.** A signal can arrive while the main flow is part-way through setting the tree aside, and restoring from the handler at that moment would race git against git over the same index. The handler passes the signal on to every child first, so a step waiting on one ends, then waits for the step to finish and restores from whatever state it left — which the record makes safe from any state at all.
///
/// **An interruption keeps the gate for good.** The handler's restore is the process's last act before it exits, and the main thread must not go on to launch the next run in the gap between the two; a gate that is never given back is what stops it, with no second `exit` racing the first.
///
/// **The lock is held until ``close()``, not until the tree is back.** The second run is still this run's: a second `run --without` started while it runs would set the tree aside under it, and the first run would then report the tests failing with the change that it had put back.
///
/// **A failed restore is never forgotten.** Once the tree could not be put back, every later finish — the handler's included — reports that again rather than that there was nothing to do, since the one answer that must never be given over missing work is that the tree is as it was.
public final class SetAsideSession: @unchecked Sendable {
    public let record: SetAsideRecord
    public let store: SetAsideStore
    /// Every process this run starts, so a signal can reach them and the watcher can end them.
    public let children: SetAsideChildren
    private let lock: SetAsideLock
    private let gate = NSLock()
    private var state = State.recorded
    private var interrupted = false

    private init(record: SetAsideRecord, store: SetAsideStore, lock: SetAsideLock, children: SetAsideChildren) {
        self.record = record
        self.store = store
        self.lock = lock
        self.children = children
    }
}

public extension SetAsideSession {
    /// Where the tree stands.
    enum State: Sendable {
        /// The record is written and nothing in the tree has been touched.
        case recorded
        /// The tree is set aside, possibly only in part.
        case aside
        /// Put back and checked, or never touched; the record is gone.
        case finished
        /// Could not be put back exactly; the record and every copy are kept.
        case failed(SetAsideError)
    }

    /// How a finish went, when it did.
    enum Finish: Sendable {
        /// Nothing had been set aside; the record is gone.
        case untouched
        /// Put back and checked by content hash.
        case restored(SetAside.Restored)
        /// An earlier step already put the tree back.
        case alreadyBack
    }

    /// Takes the working tree's lock, refuses if a record is already there, and captures the pathspecs into a new record — the tree is untouched when this returns.
    ///
    /// `since` is a commit git has already resolved, and makes the change captured the one committed on top of it rather than the one in the tree; the caller resolves it before this is called, so a revision git cannot name is refused before the lock is taken.
    ///
    /// `cancelled` is asked while the changes are copied: once it answers `true` the capture stops, takes its copies with it, and throws ``SetAsideError/cancelled``.
    static func begin(pathspecs: [String], from directory: URL, since: String? = nil, cancelled: () -> Bool = { false }) throws -> SetAsideSession {
        try begin(from: directory) { store, children in
            try SetAside.capture(pathspecs: pathspecs, from: directory, into: store, children: children, since: since, cancelled: cancelled)
        }
    }

    /// Takes the working tree's lock, refuses if a record is already there, and records line `number` of `path` to be commented out — the tree is untouched when this returns.
    ///
    /// One file is copied, so there is no capture long enough to cancel: a signal that arrives meanwhile is found when the caller attaches its handler, and the record goes with ``finish()``.
    static func begin(line number: Int, of path: String, from directory: URL) throws -> SetAsideSession {
        try begin(from: directory) { store, children in
            try SetAside.capture(line: number, of: path, from: directory, into: store, children: children)
        }
    }

    private static func begin(from directory: URL, capture: (SetAsideStore, SetAsideChildren) throws -> SetAsideRecord) throws -> SetAsideSession {
        guard let root = GitContext.discoverRoot(from: directory) else {
            throw SetAsideError.notARepository
        }
        let store = SetAsideStore(repositoryRoot: root)
        guard let lock = try SetAsideLock.take(for: store, as: .run) else {
            throw SetAsideError.busy(holder: SetAsideLock.holder(for: store), record: try? store.record())
        }
        if let existing = try store.record() {
            throw SetAsideError.unrestored(existing)
        }
        let children = SetAsideChildren()
        let record = try capture(store, children)
        // From here on every child's session is written into the store as well as told to the watcher, so a
        // restore that finds both the run and its watcher gone still knows what to end first.
        children.record(into: store.sessionsURL)
        return SetAsideSession(record: record, store: store, lock: lock, children: children)
    }

    /// Where the tree stands now.
    var current: State {
        gate.withLock { state }
    }

    /// Whether the tree could not be put back, with the record and every copy kept — which every later finish says again.
    var hasFailed: Bool {
        if case .failed = current {
            return true
        }
        return false
    }

    /// Sets the recorded paths aside, or stops and puts them back when one changed under it.
    ///
    /// After an interruption this never returns — the handler keeps the gate while it restores and exits — which is exactly what the main flow needs: it must not go on to run anything. Throws with the tree possibly part set aside, which ``finish()`` then puts back — unless what it throws says the work is not back, which ``finish()`` then says again rather than trying anything over it.
    func setAsideTree() throws -> SetAside.Outcome? {
        gate.lock()
        defer { gate.unlock() }
        guard !interrupted, case .recorded = state else {
            return nil
        }
        state = .aside
        do {
            let outcome = try SetAside(store: store, children: children).setAside(record)
            if case .stopped = outcome {
                state = .finished
                children.record(into: nil)
            }
            return outcome
        } catch let error as SetAsideError where error.workIsOut {
            state = .failed(error)
            throw error
        }
    }

    /// Puts the tree back — or, if it was never touched, just removes the record — keeping the lock until ``close()``.
    ///
    /// Throws when the tree could not be put back exactly, in which case the record and every copy stay where they are — and throws the same again on every later call.
    @discardableResult
    func finish() throws -> Finish {
        gate.lock()
        defer { gate.unlock() }
        return try finishHoldingGate()
    }

    /// For a signal handler: passes `number` on to every child, then ends them, marks the session interrupted and finishes it — keeping the gate so the main flow cannot start anything else before the process exits.
    ///
    /// The children go before the restore, not after it: a test still running, or a git still writing, could otherwise write into the tree after it was put back.
    func interrupt(forwarding number: Int32) -> Result<Finish, SetAsideError> {
        children.signalAll(number)
        gate.lock()
        interrupted = true
        children.endAll(patience: 5)
        do {
            return try .success(finishHoldingGate())
        } catch let error as SetAsideError {
            return .failure(error)
        } catch {
            return .failure(.store("\(error)"))
        }
    }

    /// Lets go of the lock — once the second run is over, so no other `run --without` can set the tree aside under it.
    func close() {
        lock.release()
    }

    /// The commit HEAD names now, when it is no longer the one the record was made at.
    func headNow() -> String? {
        let git = SetAsideGit(directory: store.repositoryRoot, children: children)
        guard let now = try? git.text(["rev-parse", "--verify", "--quiet", "HEAD"]), !now.isEmpty, now != record.head else {
            return nil
        }
        return now
    }

    private func finishHoldingGate() throws -> Finish {
        switch state {
        case let .failed(error):
            throw error
        case .finished:
            return .alreadyBack
        case .recorded:
            children.record(into: nil)
            try store.discard()
            state = .finished
            return .untouched
        case .aside:
            do {
                let restored = try SetAside(store: store, children: children).restore(record)
                children.record(into: nil)
                state = .finished
                return .restored(restored)
            } catch let error as SetAsideError {
                state = .failed(error)
                throw error
            }
        }
    }
}

public extension SetAsideSession {
    /// The refusal a `sift run` owes when the working tree it would build is missing set-aside changes, or `nil` when it is not.
    ///
    /// Every `sift run` asks, not only `--without`: while the changes are out of the tree, any build or test of it builds something that is not the caller's code.
    static func refusal(for directory: URL) -> SetAsideError? {
        guard let root = GitContext.discoverRoot(from: directory) else {
            return nil
        }
        return refusal(inRepository: root)
    }

    /// The same refusal, for a repository whose root the caller has already found.
    ///
    /// **It never says nobody is putting the tree back while a watcher is about to.** Between a run dying and its watcher taking the lock, the lock is free and the record still there; so while a watcher is alive and the lock free, this waits — for the watcher to take the lock, which makes the answer "its watcher is putting them back now", or to be gone, after which the record says whether anything is still out.
    static func refusal(inRepository root: URL) -> SetAsideError? {
        let store = SetAsideStore(repositoryRoot: root)
        let deadline = Date().addingTimeInterval(watcherPatience)
        while true {
            let record: SetAsideRecord?
            do {
                record = try store.record()
            } catch let error as SetAsideError {
                return error
            } catch {
                return .store("\(error)")
            }
            guard let record else {
                return nil
            }
            if SetAsideLock.isHeld(for: store) {
                return .busy(holder: SetAsideLock.holder(for: store), record: record)
            }
            guard SetAsideLock.isWatched(for: store), Date() < deadline else {
                return .unrestored(record)
            }
            usleep(20000)
        }
    }

    /// Puts back a set-aside whose process is gone: `sift run --restore`.
    ///
    /// Refuses while another process holds the lock — the run is mid-way and will restore the tree itself, or its watcher is doing so now — and restoring under it would race it. **Ends whatever the run left running before it touches anything**, from the sessions the run wrote into the store, each checked against the time its leader started: when the run and its watcher are both gone there is nobody else to do it, and a writer the run left behind would otherwise write into the tree after it was put back. Answers `nil` when there is nothing to restore.
    static func restoreAbandoned(in directory: URL) throws -> SetAside.Restored? {
        guard let root = GitContext.discoverRoot(from: directory) else {
            throw SetAsideError.notARepository
        }
        let store = SetAsideStore(repositoryRoot: root)
        waitForAWatcherToTakeTheLock(in: store)
        guard let lock = try SetAsideLock.take(for: store, as: .restore) else {
            throw SetAsideError.busy(holder: SetAsideLock.holder(for: store), record: try? store.record())
        }
        defer { lock.release() }
        guard let record = try store.record() else {
            // A capture killed before its record was written leaves copies nobody points at, and nothing else.
            try? FileManager.default.removeItem(at: store.directory)
            return nil
        }
        let ended = SetAsideChildren.end(sessions: SetAsideChildren.sessions(in: store.sessionsURL))
        return try SetAside(store: store).restore(record, requested: true).ending(ended)
    }

    /// Deletes `.sift/` for `sift reset`, holding the set-aside lock while it does — so it refuses, in the words a busy run would, while a `run --without` holds the tree, even in its second pass when no record stands, and no run can start under it.
    ///
    /// Everything goes but the lock file, which goes last, still held: a run started a moment later makes a new one and finds `.sift/` already empty.
    ///
    /// The trailing closure runs between the first look at `.sift` and the lock being taken, where the refusal can wait for a watcher: a seam for tests.
    static func clearCache(in root: URL, beforeTheLock: () -> Void = {}) throws {
        // Read before the lock is taken, since taking it creates a file through whatever `.sift` is.
        let cache = SiftPaths.cache(in: root)
        let checked = CacheEntry(at: cache)
        if let reason = PathKind.of(cache).refusal {
            throw PathKind.Refused(path: cache.path, reason: reason)
        }
        let store = SetAsideStore(repositoryRoot: root)
        if let refusal = refusal(inRepository: root) {
            throw refusal
        }
        beforeTheLock()
        guard let lock = try SetAsideLock.take(for: store, as: .reset, excludingCache: false) else {
            throw SetAsideError.busy(holder: SetAsideLock.holder(for: store), record: try? store.record())
        }
        defer { lock.release() }
        // Read again under the lock, since the refusal above can wait seconds: a `.sift` swapped for a link or another directory by then is refused with nothing deleted. The lock file itself can already have been created through such a link, and the deletes below still go by path, so a swap in the moment after this read is not caught.
        guard let now = CacheEntry(at: cache), now.isDirectory, checked == nil || now == checked else {
            let reason = PathKind.of(cache).refusal ?? "not the directory that was there before the lock was taken, so nothing in it was deleted"
            throw PathKind.Refused(path: cache.path, reason: reason)
        }
        if let record = try store.record() {
            throw SetAsideError.unrestored(record)
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: cache.path) where name != store.lockURL.lastPathComponent {
            try FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
        unlink(store.lockURL.path)
        lock.release()
        rmdir(cache.path)
    }

    /// How long a refusal waits for a live watcher to take the lock before it answers from the record alone — far longer than the moment it takes, and short enough that a watcher wedged some other way is not waited on for good.
    private static let watcherPatience: TimeInterval = 15

    /// Waits, for a while, as long as a watcher is alive with the lock free and a record standing — the moment between its run dying and its taking the lock.
    private static func waitForAWatcherToTakeTheLock(in store: SetAsideStore) {
        let deadline = Date().addingTimeInterval(watcherPatience)
        while Date() < deadline, (try? store.record()) != nil, !SetAsideLock.isHeld(for: store), SetAsideLock.isWatched(for: store) {
            usleep(20000)
        }
    }

    /// The entry at a path itself, never what a link there points to: its type, device and inode, which a swap for another entry changes.
    private struct CacheEntry: Equatable {
        let type: mode_t
        let device: dev_t
        let inode: ino_t

        var isDirectory: Bool {
            type == S_IFDIR
        }

        init?(at url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            type = info.st_mode & S_IFMT
            device = info.st_dev
            inode = info.st_ino
        }
    }
}
