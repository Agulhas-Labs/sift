//
// Copyright © Agulhas Labs
//

import Foundation

/// Where a repository's index is opened: its file under `.sift/`, or in memory where the tree cannot be written (Docs/Design.md §2).
///
/// Only a permission refusal sends the index to memory — no write permission, or a read-only volume. Any other failure making a missing `.sift/` is thrown, so a fault that is not about permissions is never answered around. An existing `.sift/` or `index.db` is judged by `access` alone, and any refusal it gives goes to memory.
enum IndexLocation: Equatable {
    case file(String)
    case memory

    /// The path ``IndexStore`` opens for this location.
    var databasePath: String {
        switch self {
        case let .file(path): path
        case .memory: IndexStore.inMemoryPath
        }
    }

    /// The file at `databasePath` when its directory exists writable or can be made, and memory when it cannot.
    ///
    /// An existing `.sift/` or `index.db` that is not writable goes to memory too: a tree indexed once and then made read-only cannot keep that file fresh, and SQLite opening it read-write would fail on the first write.
    static func resolve(databasePath: String) throws -> IndexLocation {
        let directory = (databasePath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: directory) {
            return existing(databasePath, in: directory)
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch where isPermissionRefusal(error) {
            return .memory
        }
        return .file(databasePath)
    }

    /// Where ``resolve(databasePath:)`` would open the index, worked out without making anything: a missing directory is judged by whether the nearest directory above it that exists can be written.
    ///
    /// For a caller that must not pay for an index in memory and must not leave a `.sift/` behind when it then declines to open one. Any refusal `access` gives counts as memory, so where this cannot tell, the caller declines.
    static func expected(databasePath: String) -> IndexLocation {
        let directory = (databasePath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: directory) {
            return existing(databasePath, in: directory)
        }
        var ancestor = (directory as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: ancestor), ancestor != "/", !ancestor.isEmpty {
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return access(ancestor, W_OK) == 0 ? .file(databasePath) : .memory
    }

    /// The location for `databasePath` in `directory`, which exists: the file where both can be written, memory otherwise.
    private static func existing(_ databasePath: String, in directory: String) -> IndexLocation {
        let fileWritable = !FileManager.default.fileExists(atPath: databasePath) || access(databasePath, W_OK) == 0
        return access(directory, W_OK) == 0 && fileWritable ? .file(databasePath) : .memory
    }

    /// Whether `error`, or any error under it, is a refusal to write for want of permission or on a read-only volume.
    static func isPermissionRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        let cocoaRefusals = [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue]
        if nsError.domain == NSCocoaErrorDomain, cocoaRefusals.contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [EACCES, EPERM, EROFS].contains(Int32(nsError.code)) {
            return true
        }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map(isPermissionRefusal) ?? false
    }
}
