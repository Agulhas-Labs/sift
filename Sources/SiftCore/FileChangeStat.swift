//
// Copyright © Agulhas Labs
//

import Foundation

/// A file's size and the moment it last changed, read in one `stat`: what the index stores in a row's `mtime` column.
///
/// The moment is the later of the file's mtime and its ctime, because the ctime is the half nothing can put back: `touch -r`, `cp -p`, `rsync -t` and an archive extraction restore the mtime, but every write, and every restore of the mtime itself, moves the ctime to the present. A row's moment is what the semantic axis compares with the store's build anchor, so an edit made after a build with its mtime restored still reads as written after the build (Docs/Design.md §2). It over-claims where the ctime moved with no edit (a `chmod`, an extended attribute), the direction the contract allows.
struct FileChangeStat: Equatable {
    let size: Int64
    /// Seconds since 1970: the later of the file's mtime and ctime.
    let changed: Double

    /// The stat of the file at `path`; `nil` when it cannot be statted.
    static func of(path: String) -> FileChangeStat? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        let statusChanged = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return FileChangeStat(size: Int64(info.st_size), changed: Swift.max(modified, statusChanged))
    }
}
