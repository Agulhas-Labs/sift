//
// Copyright © Agulhas Labs
//

import Foundation

/// Replaces a file's contents all at once: a temporary file beside it, renamed into place — the shared mechanism behind `SetAsideStore`, `TestDurationStore` and `ShardLedger`'s own atomic writes.
struct DurableFile {
    /// Replaces `url`'s contents with `data`, atomically: a temporary file in `url`'s own directory (so the rename stays on one volume), written whole, then renamed into place.
    ///
    /// `fsync` also flushes the temporary file and the directory before returning, for a caller whose file must survive a crash the instant the rename lands rather than merely on the next `sync`. In `replace(_:with:fsync:createDirectory:cleanUpOnFailure:beforeRename:)`, the directory is made first when a caller cannot assume it exists, and the temporary is best-effort removed after a write, the step before the rename, or the rename itself — unless a caller is relying on it being left behind as evidence of the failed attempt.
    ///
    /// The last parameter of `replace(_:with:fsync:createDirectory:cleanUpOnFailure:beforeRename:)` runs after the temporary is written and synced (where `fsync` asked for that) and before the rename that publishes it — a seam with nothing to do by default, for a test proving what an interruption right there does: `url`'s old contents must still read back, and the temporary must be gone where cleanup on failure was left at its default, the same as a write or rename failure leaves it.
    static func replace(
        _ url: URL,
        with data: Data,
        fsync: Bool,
        createDirectory: Bool = false,
        cleanUpOnFailure: Bool = true,
        beforeRename: () throws -> Void = {}
    ) throws {
        let directory = url.deletingLastPathComponent()
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        do {
            if fsync {
                guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                    throw DurableFileError.create(temporary: temporary.lastPathComponent)
                }
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } else {
                try data.write(to: temporary)
            }
            try beforeRename()
        } catch {
            if cleanUpOnFailure {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            if cleanUpOnFailure {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw DurableFileError.rename(temporary: temporary.lastPathComponent, reason: reason)
        }
        if fsync {
            synchronize(directory: directory)
        }
    }

    /// Flushes a directory's entries, so a rename into it survives the machine going down.
    static func synchronize(directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return
        }
        fsync(descriptor)
        close(descriptor)
    }
}
