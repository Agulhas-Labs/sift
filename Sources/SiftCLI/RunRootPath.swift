//
// Copyright © Agulhas Labs
//

import Foundation

/// The directory spelling a `--root` run gives its command as `$PWD`, the logical one a shell's `cd` keeps.
///
/// Symbolic links are never resolved; `.`, `..` and repeated slashes are collapsed lexically, as `cd` does.
struct RunRootPath {
    /// The absolute, lexically normalised form of `directory`, joined to the caller's logical directory when it is relative.
    ///
    /// The caller's logical directory is the inherited `PWD` when it names the same directory as `current`, and `current` otherwise.
    static func logical(_ directory: String, inheritedPWD: String?, current: String) -> String {
        guard !directory.hasPrefix("/") else {
            return normalise(directory)
        }
        var base = current
        if let inheritedPWD, inheritedPWD.hasPrefix("/"), sameDirectory(inheritedPWD, current) {
            base = inheritedPWD
        }
        return normalise(base + "/" + directory)
    }

    /// Changes the process into `logical` when it names a directory, and reports whether it did.
    ///
    /// The logical path is the one a shell's `cd` goes to, so `..` after a symbolic link lands in the logical parent.
    static func changeDirectory(logical: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logical, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return FileManager.default.changeCurrentDirectoryPath(logical)
    }

    /// The `PWD` for a process now standing in `current`: `logical` when it names that directory, `current` otherwise.
    static func pwd(logical: String, current: String) -> String {
        sameDirectory(logical, current) ? logical : current
    }

    /// Whether two paths name one directory, by device and inode.
    static func sameDirectory(_ first: String, _ second: String) -> Bool {
        var one = stat()
        var other = stat()
        guard stat(first, &one) == 0, stat(second, &other) == 0 else {
            return false
        }
        return one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }

    /// Collapses `.`, `..` and repeated slashes in an absolute path, without touching the filesystem.
    static func normalise(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                _ = parts.popLast()
            default:
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
