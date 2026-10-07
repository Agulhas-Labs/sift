//
// Copyright © Agulhas Labs
//

import Foundation

/// The lock one process holds while it may change a working tree's set-aside.
///
/// `flock` rather than a file whose existence is the lock, for the reason ``FileLock`` gives: the kernel lets go when the holder dies, however it dies, so "is the process that made this record still running?" has an exact answer — try the lock — with no process table to read and no pid that could have been reused. Held on a descriptor opened close-on-exec, so no command the holder launches can keep it alive after the holder has gone.
///
/// **The holder writes who it is into the file,** because more than one kind of process takes this lock — the run, its watcher once the run is gone, a `--restore` — and a refusal that named the run's dead pid while its watcher was the one restoring would send the reader after a process that no longer exists. The content is only ever read while the lock is held, so a stale one is never believed.
public final class SetAsideLock: @unchecked Sendable {
    private let gate = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }
}

public extension SetAsideLock {
    /// Which kind of process holds the lock.
    enum Role: String, Sendable {
        /// A `run --without`, from its set-aside to the end of its second run.
        case run
        /// The watcher of a run that is gone, putting its tree back.
        case watcher
        /// A `run --restore`.
        case restore
        /// A `sift reset`, deleting `.sift/` — which it may only do while nothing else can change the set-aside.
        case reset
    }

    /// Who holds the lock, as the holder wrote it.
    struct Holder: Sendable, Equatable {
        public let pid: Int32
        public let role: Role
    }

    /// Takes the lock for `store`'s working tree, or answers `nil` when another process holds it.
    ///
    /// `waiting` blocks until the holder lets go instead, which only the watcher does: it has nothing else to do, and the holder it waits on is by then either dead or finishing a restore.
    ///
    /// The cache is left out of the exclude file only by a caller about to delete `.sift/` itself, which has no cache left to keep out of git and no business writing the repository's exclude file on the way out.
    static func take(for store: SetAsideStore, as role: Role, waiting: Bool = false, excludingCache: Bool = true) throws -> SetAsideLock? {
        // The first write under `.sift/` on every set-aside path — `sift run --restore` in a repository that
        // has never been indexed included — so the ignore rule has to be in place before it.
        if excludingCache {
            GitContext(repoRoot: store.repositoryRoot).ensureCacheExcluded()
        }
        try FileManager.default.createDirectory(at: store.lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(store.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw SetAsideError.store("could not open \(store.lockURL.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        while flock(descriptor, LOCK_EX | (waiting ? 0 : LOCK_NB)) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            close(descriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw SetAsideError.store("could not lock \(store.lockURL.lastPathComponent): \(String(cString: strerror(code)))")
        }
        let line = Array("\(getpid()) \(role.rawValue)\n".utf8)
        ftruncate(descriptor, 0)
        _ = line.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return SetAsideLock(descriptor: descriptor)
    }

    /// Whether another process holds the lock right now — the question a refusal needs answered before it can say which refusal it is.
    static func isHeld(for store: SetAsideStore) -> Bool {
        isLocked(store.lockURL, against: LOCK_SH)
    }

    /// Takes a shared hold on `.sift/set-aside.watch` for a watcher, kept until the process exits; `nil` when the file cannot be opened.
    ///
    /// Shared, because two watchers can be alive at once — one whose run has just let it go, still leaving, beside the next run's.
    static func watch(for store: SetAsideStore) -> SetAsideLock? {
        try? FileManager.default.createDirectory(at: store.watchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(store.watchURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            return nil
        }
        while flock(descriptor, LOCK_SH) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                return nil
            }
        }
        return SetAsideLock(descriptor: descriptor)
    }

    /// Whether any watcher is alive for this working tree.
    ///
    /// With the lock free and a record standing, that is a watcher whose run is gone and which is about to put the tree back — the one moment a refusal saying nobody will is wrong.
    static func isWatched(for store: SetAsideStore) -> Bool {
        isLocked(store.watchURL, against: LOCK_EX)
    }

    /// Whether `url` is locked by somebody else in a way that excludes a hold of kind `operation`.
    private static func isLocked(_ url: URL, against operation: Int32) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        while flock(descriptor, operation | LOCK_NB) != 0 {
            if errno == EINTR {
                continue
            }
            return errno == EWOULDBLOCK
        }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Who holds the lock, when somebody does and wrote it down.
    static func holder(for store: SetAsideStore) -> Holder? {
        guard isHeld(for: store),
              let text = try? String(contentsOf: store.lockURL, encoding: .utf8)
        else {
            return nil
        }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 2, let pid = Int32(fields[0]), let role = Role(rawValue: String(fields[1])) else {
            return nil
        }
        return Holder(pid: pid, role: role)
    }

    func release() {
        gate.withLock {
            guard descriptor >= 0 else {
                return
            }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}
