//
// Copyright © Agulhas Labs
//

import Foundation

/// A file's device + inode — the pair that distinguishes "the same file" from "a file at the same path".
///
/// Path equality is not identity: a deleted file leaves the path free for a replacement, and an open descriptor follows the original inode into the grave. Anything caching an open handle across the lifetime of a long-running process has to compare this, not the path.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    /// The identity of the file at `path`, or `nil` when nothing is there.
    init?(path: String) {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        device = status.st_dev
        inode = status.st_ino
    }
}
