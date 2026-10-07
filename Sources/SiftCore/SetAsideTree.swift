//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation

/// The working tree as a set-aside touches it: every call made through a path's own bytes, and every move that could land on somebody's file made exclusive.
///
/// **Bytes, because a name is put back in the bytes it had.** `URL` and `FileManager` hand the kernel a decomposed spelling of any name outside ASCII, so a file they create comes back under other bytes than the ones it left under — equal to the eye, and to `git status`, and still not the file that was there.
///
/// **Exclusive, because a set-aside is never the only thing writing.** Nothing at a user's path is ever checked and then written: every move that could land on something is a `RENAME_EXCL`, which fails rather than replaces, or a `RENAME_SWAP`, after which what came out is looked at; and nothing is ever unlinked in the tree — what has to go is moved into the store first and looked at there.
struct SetAsideTree {
    /// The repository root, as a path string with no trailing separator.
    let root: String

    init(root: URL) {
        let path = root.path
        self.root = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }
}

extension SetAsideTree {
    /// The absolute spelling of a repository-relative path.
    func absolute(_ relative: String) -> String {
        "\(root)/\(relative)"
    }

    /// `relative` in the bytes the file system holds it under, component by component, falling back to git's own spelling for anything that does not exist.
    ///
    /// git precomposes a decomposed name it reads from a directory, so the path it prints can be canonically the same as the one on disk and still not the same bytes; only the directory itself can say which bytes are there.
    func onDisk(_ relative: String, caseSensitive: Bool, cache: inout [String: [String]]) -> String {
        var resolved: [String] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            let parent = resolved.joined(separator: "/")
            let names: [String]
            if let cached = cache[parent] {
                names = cached
            } else {
                names = Self.names(in: parent.isEmpty ? root : absolute(parent))
                cache[parent] = names
            }
            let bytes = Array(component.utf8)
            let match = names.first { Array($0.utf8) == bytes }
                ?? names.first { $0 == component }
                ?? (caseSensitive ? nil : names.first { $0.lowercased() == component.lowercased() })
            resolved.append(match ?? component)
        }
        return resolved.joined(separator: "/")
    }

    private static func names(in directory: String) -> [String] {
        guard let stream = opendir(directory) else {
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(bytes: raw.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            if let name, name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    /// The device a path — or the nearest directory above it that exists — lives on.
    func device(of relative: String) -> dev_t? {
        var components = relative.split(separator: "/").map(String.init)
        while true {
            var info = stat()
            let path = components.isEmpty ? root : absolute(components.joined(separator: "/"))
            if lstat(path, &info) == 0 {
                return info.st_dev
            }
            guard !components.isEmpty else {
                return nil
            }
            components.removeLast()
        }
    }

    static func device(atPath path: String) -> dev_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    /// Moves `from` to `to` in one step, failing rather than replacing anything already at `to`; answers `errno` on failure, `0` on success.
    static func moveExclusively(_ from: String, to: String) -> Int32 {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// Exchanges what stands at `one` and `other` in one step, so neither is ever replaced; answers `errno` on failure — `ENOTSUP` on a volume that cannot, such as HFS+ — and `0` on success.
    static func swap(_ one: String, _ other: String) -> Int32 {
        renamex_np(one, other, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    /// Creates every directory above `relative` that is missing, in the bytes `relative` spells them; answers `errno` for the first that could not be made — something other than a directory standing in the way included.
    func makeParents(of relative: String) -> Int32 {
        var components = relative.split(separator: "/").map(String.init)
        components.removeLast()
        var built: [String] = []
        for component in components {
            built.append(component)
            let path = absolute(built.joined(separator: "/"))
            if mkdir(path, 0o777) == 0 {
                continue
            }
            let code = errno
            var info = stat()
            guard code == EEXIST, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                return code == EEXIST ? ENOTDIR : code
            }
        }
        return 0
    }

    /// The first directory above `relative` that exists as something other than a directory, repository-relative.
    func obstruction(above relative: String) -> String? {
        var components = relative.split(separator: "/").map(String.init)
        components.removeLast()
        var built: [String] = []
        for component in components {
            built.append(component)
            var info = stat()
            guard lstat(absolute(built.joined(separator: "/")), &info) == 0 else {
                return nil
            }
            if info.st_mode & S_IFMT != S_IFDIR {
                return built.joined(separator: "/")
            }
        }
        return nil
    }

    /// Removes the directories that removing `paths` left empty, deepest first, stopping at the first that is not empty.
    ///
    /// Walked by path components rather than by comparing locations, so the repository root is never reached by a comparison that a differently spelled path could get wrong: the walk simply ends when the components do.
    func pruneEmptyDirectories(above paths: [String]) {
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                guard rmdir(absolute(components.joined(separator: "/"))) == 0 else {
                    break
                }
                components.removeLast()
            }
        }
    }

    /// Moves what stands at `source` — an absolute path, in the tree or in the store — to a free `.sift-kept-` name beside `relative`, and answers that name, repository-relative.
    ///
    /// **Never over anything**: each candidate is taken by an exclusive rename, and one somebody else holds is passed over for the next, so the name is never checked and then written. **Never too long for the file system**: a name that would pass the 255 bytes one may hold keeps as much of itself as fits and a hash of the whole. Throws — with the reason — when neither can be done, and `source` is then left exactly where it was.
    func keep(_ source: String, beside relative: String, id: String) throws -> String {
        var failure: Int32 = 0
        for attempt in 1 ... 100 {
            let name = keptName(for: relative, id: id, attempt: attempt)
            let parents = makeParents(of: name)
            guard parents == 0 else {
                failure = parents
                break
            }
            let code = Self.moveExclusively(source, to: absolute(name))
            if code == 0 {
                return name
            }
            failure = code
            guard code == EEXIST else {
                break
            }
        }
        throw SetAsideError.store("could not be kept beside \(relative) (\(String(cString: strerror(failure))))")
    }

    /// The `attempt`th name `keep` tries beside `relative`.
    func keptName(for relative: String, id: String, attempt: Int = 1) -> String {
        var components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = components.removeLast()
        let suffix = ".sift-kept-\(id.prefix(8))" + (attempt > 1 ? "-\(attempt)" : "")
        return (components + [Self.fitted(name, suffix: suffix)]).joined(separator: "/")
    }

    /// `name` then `suffix` — or, where that would pass the 255 bytes a name may hold, as much of `name` as fits, a hash of the whole of it, and `suffix`, so the result still says whose it is and is still told apart from any other name's.
    static func fitted(_ name: String, suffix: String) -> String {
        let limit = 255
        guard name.utf8.count + suffix.utf8.count > limit else {
            return name + suffix
        }
        let hash = "-" + SetAsideFingerprint.sha256(of: name).prefix(12)
        let room = limit - suffix.utf8.count - hash.utf8.count
        var kept = ""
        for character in name {
            guard kept.utf8.count + String(character).utf8.count <= room else {
                break
            }
            kept.append(character)
        }
        return kept + hash + suffix
    }

    /// Paths or index lines for a `-z` stdin, each terminated rather than separated.
    static func terminated(_ items: [String]) -> Data {
        Data(items.map { "\($0)\u{0}" }.joined().utf8)
    }
}
