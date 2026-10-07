//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// What stands at a path, in enough detail to say whether it is exactly what a set-aside record says it should be.
///
/// **Read through the path's own bytes, never through `URL` or `FileManager`,** which hand the kernel a decomposed spelling of any name outside ASCII: a lookup still finds the file on a volume that ignores the difference, but anything created that way is created under the other spelling, and a name that comes back in other bytes has not come back exactly.
enum SetAsideFingerprint: Codable, Equatable {
    case absent
    case file(permissions: Int, sha256: String)
    case symlink(target: String)
    case directory
    case other
}

extension SetAsideFingerprint {
    /// What kind of thing stands at a path, read without its bytes.
    enum Kind {
        case absent
        case file(permissions: Int)
        case symlink
        case directory
        case other
    }

    /// What `state` reads as once it is on disk.
    init(_ state: SetAsideRecord.WorktreeState) {
        switch state {
        case .absent: self = .absent
        case let .file(permissions, sha256, _): self = .file(permissions: permissions, sha256: sha256)
        case let .symlink(target): self = .symlink(target: target)
        }
    }

    /// What stands at `path` now, without following a symbolic link.
    static func read(_ path: String) throws -> SetAsideFingerprint {
        switch try kind(path) {
        case .absent: .absent
        case let .file(permissions): try .file(permissions: permissions, sha256: sha256(path))
        case .symlink: try .symlink(target: target(of: path))
        case .directory: .directory
        case .other: .other
        }
    }

    static func kind(_ path: String) throws -> Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                return .absent
            }
            throw SetAsideError.store("could not read \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return switch info.st_mode & S_IFMT {
        case S_IFREG: .file(permissions: Int(info.st_mode & 0o7777))
        case S_IFLNK: .symlink
        case S_IFDIR: .directory
        default: .other
        }
    }

    /// The SHA-256 of a file's bytes, read in chunks so a large file never has to fit in memory.
    ///
    /// The chunk is left uninitialised: every path a set-aside touches is hashed more than once, and zeroing a megabyte per small file was the most expensive thing a large set-aside did.
    static func sha256(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SetAsideError.store("could not open \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw SetAsideError.store("could not read \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(errno)))")
            }
            guard count > 0 else {
                break
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer.prefix(count)))
        }
        return hex(hasher.finalize())
    }

    /// The SHA-256 of `text`'s UTF-8 bytes, as hex.
    static func sha256(of text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Where a symbolic link points, exactly as it was written.
    static func target(of path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count >= 0 else {
            throw SetAsideError.store("could not read the link \(URL(fileURLWithPath: path).lastPathComponent): \(String(cString: strerror(errno)))")
        }
        guard let target = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            throw SetAsideError.store("the link \(URL(fileURLWithPath: path).lastPathComponent) points at a name that is not UTF-8")
        }
        return target
    }

    var described: String {
        switch self {
        case .absent: "nothing"
        case let .file(permissions, sha256): "a file (mode \(String(permissions, radix: 8)), sha256 \(sha256.prefix(12))…)"
        case let .symlink(target): "a symbolic link to \(target)"
        case .directory: "a directory"
        case .other: "something that is neither a file nor a link"
        }
    }
}
