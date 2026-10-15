//
// Copyright © Agulhas Labs
//

import Foundation

/// The places outside code that write a name and that a rename has to change too: DocC links, doc comments, comments and string literals in Swift files, lines of Markdown files, and file names.
///
/// Read from the working tree's files, never the store, so it is the same with a store and without. Each file is read once as bytes and searched for the name's bytes; only a Swift file that holds them is lexed, by ``SwiftMentionLexer``. The unit is a line, counted once under the first of DocC link, doc comment, comment, string literal that it holds. A DocC link is a hit between the (2k+1)th and (2k+2)th run of exactly two backticks on its line, in a doc comment or a Markdown file. Matching is whole-word and case-sensitive; a name that starts lowercase, which is also an ordinary word, counts in a doc comment, a comment or a Markdown line only inside a backtick span that reads as a reference to it (the name, `name(…)`, or `Owner.name`), in a string literal only when the literal is the name or backticks it so, in a Markdown fenced block only where it reads as code (after a `.` or before a `(`), and is never matched against file names.
struct NonCodeMentions: Equatable {
    /// The files with a listed line, in path order.
    let files: [File]
    /// The files whose names match, in path order.
    let fileNames: [FileName]
    /// How many Swift files were read.
    let swiftFilesRead: Int
    /// How many Markdown files were read.
    let markdownFilesRead: Int

    /// Whether nothing at all was found.
    var isEmpty: Bool {
        files.isEmpty && fileNames.isEmpty
    }

    /// How many lines across the tree were counted under `kind`.
    func count(of kind: Kind) -> Int {
        files.reduce(0) { total, file in total + file.lines.count { $0.kind == kind } }
    }

    /// How many listed lines also write the name in code.
    var codeLines: Int {
        files.reduce(0) { $0 + $1.codeLines }
    }

    /// Scans the repo-relative `swiftFiles` and `markdownFiles` under `root` for `name`, a Swift file the answer's conformers block already read for it taken from `reads`.
    static func scan(name: String, swiftFiles: [String], markdownFiles: [String], under root: URL, reads: TextSearchFiles.Reads? = nil) -> NonCodeMentions {
        let needle = Array(name.utf8)
        let backtickedOnly = name.first?.isLowercase ?? false
        var files: [File] = []
        for path in swiftFiles {
            guard let data = reads?.bytes(of: path, for: name) ?? FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else { continue }
            if let file = data.withUnsafeBytes({ swiftFile(path: path, needle: needle, backtickedOnly: backtickedOnly, in: $0) }) {
                files.append(file)
            }
        }
        for path in markdownFiles {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else { continue }
            if let file = data.withUnsafeBytes({ markdownFile(path: path, needle: needle, backtickedOnly: backtickedOnly, in: $0) }) {
                files.append(file)
            }
        }
        let names = backtickedOnly ? [] : (swiftFiles + markdownFiles).compactMap { fileName(of: $0, matching: name) }
        return NonCodeMentions(
            files: files.sorted { $0.path < $1.path },
            fileNames: names.sorted { $0.path < $1.path },
            swiftFilesRead: swiftFiles.count,
            markdownFilesRead: markdownFiles.count
        )
    }

    private static func swiftFile(path: String, needle: [UInt8], backtickedOnly: Bool, in source: UnsafeRawBufferPointer) -> File? {
        var kinds: [Int: Kind] = [:]
        var code: Set<Int> = []
        for hit in SwiftMentionLexer.hits(writing: [needle], in: source) {
            let kind: Kind
            switch hit.place {
            case .code:
                code.insert(hit.line)
                continue
            case .string:
                if backtickedOnly, !stringReadsAsName(hit, needle: needle, in: source) {
                    continue
                }
                kind = .string
            case .comment, .doc:
                let spans = BacktickSpans(around: hit.offset, length: needle.count, in: source, restrictedTo: backtickedOnly ? needle : nil)
                if hit.place == .doc, spans.isDocLink {
                    kind = .docLink
                } else if backtickedOnly, !spans.isBackticked {
                    continue
                } else {
                    kind = hit.place == .doc ? .doc : .comment
                }
            }
            kinds[hit.line] = min(kinds[hit.line] ?? kind, kind)
        }
        guard !kinds.isEmpty else { return nil }
        let lines = kinds.keys.sorted().map { Line(number: $0, kind: kinds[$0] ?? .comment) }
        return File(path: path, isMarkdown: false, lines: lines, codeLines: code.intersection(kinds.keys).count)
    }

    /// Whether a lowercase name's hit in a string literal counts: the literal's whole content is the name, or the name is backticked in it as a reference.
    private static func stringReadsAsName(_ hit: SwiftMentionLexer.Hit, needle: [UInt8], in source: UnsafeRawBufferPointer) -> Bool {
        if let content = hit.content {
            let whitespace: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
            let trimmed = source[content].drop { whitespace.contains($0) }.reversed().drop { whitespace.contains($0) }.reversed()
            if trimmed.elementsEqual(needle) {
                return true
            }
        }
        return BacktickSpans(around: hit.offset, length: needle.count, in: source, restrictedTo: needle).isBackticked
    }

    /// The 1-based lines of `source` that are a fence line (a run of three backticks or tildes opening or closing a fenced code block) or sit between two.
    private static func fencedLines(in source: UnsafeRawBufferPointer) -> Set<Int> {
        var fenced: Set<Int> = []
        var open: UInt8?
        var line = 1
        var start = 0
        while start < source.count {
            var end = start
            while end < source.count, source[end] != UInt8(ascii: "\n") {
                end += 1
            }
            var first = start
            while first < end, source[first] == UInt8(ascii: " ") || source[first] == UInt8(ascii: "\t") {
                first += 1
            }
            let fence = first + 3 <= end && [UInt8(ascii: "`"), UInt8(ascii: "~")].contains(source[first])
                && source[first + 1] == source[first] && source[first + 2] == source[first] ? source[first] : nil
            if let fence, open == nil || open == fence {
                open = open == nil ? fence : nil
                fenced.insert(line)
            } else if open != nil {
                fenced.insert(line)
            }
            line += 1
            start = end + 1
        }
        return fenced
    }

    private static func markdownFile(path: String, needle: [UInt8], backtickedOnly: Bool, in source: UnsafeRawBufferPointer) -> File? {
        var kinds: [Int: Kind] = [:]
        var line = 1
        var scanned = 0
        var fenced: Set<Int>?
        for offset in SwiftMentionLexer.wordHits(of: [needle], in: source) {
            while scanned < offset {
                if source[scanned] == UInt8(ascii: "\n") {
                    line += 1
                }
                scanned += 1
            }
            if backtickedOnly {
                fenced = fenced ?? fencedLines(in: source)
                if fenced?.contains(line) == true {
                    // Inside a fence the name counts when it reads as code: a member access or a call.
                    let end = offset + needle.count
                    if (offset > 0 && source[offset - 1] == UInt8(ascii: ".")) || (end < source.count && source[end] == UInt8(ascii: "(")) {
                        kinds[line] = kinds[line] ?? .markdown
                    }
                    continue
                }
            }
            let spans = BacktickSpans(around: offset, length: needle.count, in: source, restrictedTo: backtickedOnly ? needle : nil)
            let kind: Kind
            if spans.isDocLink {
                kind = .docLink
            } else if backtickedOnly, !spans.isBackticked {
                continue
            } else {
                kind = .markdown
            }
            kinds[line] = min(kinds[line] ?? kind, kind)
        }
        guard !kinds.isEmpty else { return nil }
        let lines = kinds.keys.sorted().map { Line(number: $0, kind: kinds[$0] ?? .markdown) }
        return File(path: path, isMarkdown: true, lines: lines, codeLines: 0)
    }

    /// `path` as a file name writing `name`: its stem, or the stem before a `+`, being exactly the name, else a lead where the name stands as whole camel-case words in the stem.
    static func fileName(of path: String, matching name: String) -> FileName? {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return nil }
        let stem = String(file[..<dot])
        let base = stem.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? stem
        if base == name {
            return FileName(path: path, isLead: false)
        }
        return standsAsCamelCaseWords(name, in: stem) ? FileName(path: path, isLead: true) : nil
    }

    /// Whether `name` occurs in `stem` with a camel-case word boundary at either end: `Gizmo` in `GizmoTests` and `GizmoApp`, never in `Gizmocore`.
    private static func standsAsCamelCaseWords(_ name: String, in stem: String) -> Bool {
        let characters = Array(stem)
        let needle = Array(name)
        guard let first = needle.first, !needle.isEmpty, needle.count <= characters.count else { return false }
        for start in 0 ... (characters.count - needle.count) where Array(characters[start ..< start + needle.count]) == needle {
            let end = start + needle.count
            let opens = start == 0 || !characters[start - 1].isLetter || (first.isUppercase && !characters[start - 1].isUppercase)
                || (first.isUppercase && needle.count > 1 && needle[1].isLowercase)
            let closes = end == characters.count || !characters[end].isLowercase
            if opens, closes {
                return true
            }
        }
        return false
    }
}

extension NonCodeMentions {
    /// What a listed line holds the name in, in priority order: a line is counted under the first kind it holds.
    enum Kind: Int, Comparable, CaseIterable {
        case docLink
        case doc
        case comment
        case string
        case markdown

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One file's listed lines, each under its kind.
    struct File: Equatable {
        let path: String
        let isMarkdown: Bool
        /// The listed lines, ascending.
        let lines: [Line]
        /// How many of the listed lines also write the name in code.
        let codeLines: Int

        /// The listed lines of one kind, ascending.
        func lines(of kind: Kind) -> [Int] {
            lines.filter { $0.kind == kind }.map(\.number)
        }
    }

    /// One listed line and the kind it is counted under.
    struct Line: Equatable {
        let number: Int
        let kind: Kind
    }

    /// A file whose name writes the name: an exact stem, or a lead where the name only stands as whole camel-case words in it.
    struct FileName: Equatable {
        let path: String
        let isLead: Bool
    }
}

private extension NonCodeMentions {
    /// Where a hit sits among the backtick runs of its line: inside a pair of runs of exactly two (a DocC link), or of exactly one.
    ///
    /// Given the name of a lowercase word, a span only counts when it reads as a reference to it.
    struct BacktickSpans {
        let isDocLink: Bool
        let isBackticked: Bool

        init(around offset: Int, length: Int, in source: UnsafeRawBufferPointer, restrictedTo name: [UInt8]? = nil) {
            let newline = UInt8(ascii: "\n")
            let backtick = UInt8(ascii: "`")
            var start = offset
            while start > 0, source[start - 1] != newline {
                start -= 1
            }
            var end = offset + length
            while end < source.count, source[end] != newline {
                end += 1
            }
            var before: [Int: Int] = [:]
            var after: [Int: Int] = [:]
            var opened: [Int: Int] = [:]
            var closed: [Int: Int] = [:]
            var index = start
            while index < end {
                guard source[index] == backtick else {
                    index += 1
                    continue
                }
                var run = 0
                while index + run < end, source[index + run] == backtick {
                    run += 1
                }
                if index < offset {
                    before[run, default: 0] += 1
                    opened[run] = index + run
                } else if index >= offset + length {
                    after[run, default: 0] += 1
                    closed[run] = closed[run] ?? index
                }
                index += run
            }
            func inside(_ run: Int) -> Bool {
                guard (before[run] ?? 0) % 2 == 1, (after[run] ?? 0) > 0 else { return false }
                guard let name, let from = opened[run], let to = closed[run] else { return true }
                return Self.readsAsReference(Array(UnsafeRawBufferPointer(rebasing: source[from ..< to])), to: name)
            }
            isDocLink = inside(2)
            isBackticked = isDocLink || inside(1)
        }

        /// Whether a span's `content` is the name, a call of it (`name(` up to a `)`), or a member of something (`Owner.name`, `x.name()`, DocC's `Owner/name(_:)`).
        private static func readsAsReference(_ content: [UInt8], to name: [UInt8]) -> Bool {
            if content == name {
                return true
            }
            let text = String(bytes: content, encoding: .utf8) ?? ""
            let word = String(bytes: name, encoding: .utf8) ?? ""
            if text.hasPrefix(word + "("), text.contains(")") {
                return true
            }
            return [".", "/"].contains { separator in
                text.hasSuffix(separator + word) || (text.hasSuffix(")") && text.contains(separator + word + "("))
            }
        }
    }
}
