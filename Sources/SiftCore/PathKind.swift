//
// Copyright © Agulhas Labs
//

import Foundation

/// What is at a path this tool is about to delete, read without following a symlink, so a delete never reaches through a link into a directory the tool did not make.
public enum PathKind: Equatable, Sendable {
    case absent
    case directory
    case file
    /// A symlink, with where it points as written, or `nil` when that could not be read.
    case symlink(String?)
    /// Anything else: a socket, a device, a FIFO.
    case other

    /// The kind of the entry at `url` itself, never at what a link there points to.
    public static func of(_ url: URL) -> PathKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        return switch info.st_mode & S_IFMT {
        case S_IFDIR:
            .directory
        case S_IFREG:
            .file
        case S_IFLNK:
            .symlink(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        default:
            .other
        }
    }

    /// Why a path of this kind is not deleted where a directory was expected, or `nil` for a directory or nothing at all.
    public var refusal: String? {
        switch self {
        case .absent, .directory:
            nil
        case let .symlink(target):
            "a symlink to \(target ?? "an unreadable target"), and this tool does not delete through a symlink — remove the link by hand"
        case .file, .other:
            "not a directory, so not one this tool made — remove it by hand"
        }
    }
}

public extension PathKind {
    /// A delete refused because the path is not the plain directory the tool made there.
    struct Refused: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String

        public var description: String {
            "\(path) is \(reason)"
        }
    }
}
