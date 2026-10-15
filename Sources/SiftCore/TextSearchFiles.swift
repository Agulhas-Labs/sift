//
// Copyright © Agulhas Labs
//

import Foundation

/// The Swift files git shows that hold a name's bytes anywhere, as a text search honouring `.gitignore` finds them, each with where the lexer places the name written as a word in it.
///
/// The set the store's conformers block accounts for on its last line (Docs/Design.md, the store's conformers block): git's listing, not the index's narrowed one, so manifests and the directories the index leaves out are read too. A symbolic link is never followed and a path git lists that the tree no longer has is no file of it; a file that is there but cannot be read is kept apart, never dropped.
struct TextSearchFiles {
    /// The files holding the name, in path order.
    let files: [File]
    /// The listed files that are there but could not be read, in path order.
    let unreadable: [String]

    /// Reads every path of `listing` under `root` for `name`, recording the bytes of each file holding it in `reads`; `nil` once the scan passes any of `bounds`, so a partial set is never answered.
    static func scan(name: String, listing: [String], under root: URL, bounds: Bounds, reads: Reads? = nil) -> TextSearchFiles? {
        guard listing.count <= bounds.files else { return nil }
        let needle = Array(name.utf8)
        let start = bounds.now()
        var bytes = 0
        var files: [File] = []
        var unreadable: [String] = []
        for path in listing.sorted() {
            guard start.duration(to: bounds.now()) <= bounds.deadline else { return nil }
            let absolute = root.appendingPathComponent(path).path
            var info = stat()
            guard lstat(absolute, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            // The size is judged from the `lstat` before the read, so a file past the bound is never held in memory.
            guard bytes + Int(info.st_size) <= bounds.bytes else { return nil }
            guard let data = bounds.read(absolute) else {
                unreadable.append(path)
                continue
            }
            bytes += data.count
            guard bytes <= bounds.bytes else { return nil }
            guard data.range(of: Data(needle)) != nil else {
                reads?.remember(path, holding: nil, for: name)
                continue
            }
            reads?.remember(path, holding: data, for: name)
            let places = data.withUnsafeBytes { SwiftMentionLexer.hits(writing: [needle], in: $0).map(\.place) }
            let writing: Writing = places.contains(.code) ? .code : places.isEmpty ? .insideLongerName : .commentsOrStrings
            files.append(File(path: path, writing: writing))
        }
        guard start.duration(to: bounds.now()) <= bounds.deadline else { return nil }
        return TextSearchFiles(files: files, unreadable: unreadable)
    }
}

extension TextSearchFiles {
    /// One file holding the name, and how it writes it.
    struct File: Equatable {
        let path: String
        let writing: Writing
    }

    /// Where a file writes the name as a word.
    enum Writing: Equatable {
        /// At least once in code.
        case code
        /// Only in comments, doc comments and string literals.
        case commentsOrStrings
        /// Never as a word: only inside a longer name.
        case insideLongerName
    }

    /// How far the scan may go before it gives up: a file count checked before any is read, the bytes read (a file's size is checked before it is read), and a deadline on the injected clock.
    struct Bounds {
        var files = 20000
        var bytes = 64 << 20
        var deadline: Duration = .milliseconds(300)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        /// Reads the file at an absolute path; injected so a test can see which files were read.
        var read: @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    }

    /// One answer's reads of its Swift files for one name, so the `not code` scan of `--refs` reads no file a second time: the bytes of each file holding the name, and which files were read without it.
    final class Reads {
        private var name: String?
        private var holding: [String: Data] = [:]
        private var without: Set<String> = []

        /// Records `path`'s bytes, or that it does not hold `name`; a different name starts over.
        func remember(_ path: String, holding data: Data?, for name: String) {
            if self.name != name {
                self.name = name
                holding = [:]
                without = []
            }
            if let data {
                holding[path] = data
            } else {
                without.insert(path)
            }
        }

        /// The bytes of `path` as read for `name`, empty where the read found no `name` in it, else `nil`: not read for that name.
        func bytes(of path: String, for name: String) -> Data? {
            guard self.name == name else { return nil }
            return holding[path] ?? (without.contains(path) ? Data() : nil)
        }
    }
}
