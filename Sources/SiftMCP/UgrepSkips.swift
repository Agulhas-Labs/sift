//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The files a recursive search walks that `ugrep`, behind Claude Code's `grep` function, passes over and the system grep reads.
///
/// `ugrep` skips a version-control directory — the operand included, where it is one — and every path the ignore rules in the `.gitignore` files at or below the operand ignore, a tracked file included; it reads no `.gitignore` above the operand, and neither `.git/info/exclude` nor the excludes file git's configuration names. The system grep reads every one of them.
///
/// `ugrep` reads those rules as git does, a `!` pattern keeping what an earlier one ignored, except that it matches case-sensitively whatever `core.ignorecase` says, reads some spellings its own way, and matches a pattern holding a `/` inside it against the path as the walk spells it from the operand, not from the `.gitignore`'s own directory.
struct UgrepSkips {
    /// The directory names `ugrep` never descends into.
    static let versionControlDirectories: Set<String> = [".git", ".svn", ".hg", ".bzr", ".jj", ".sl"]

    /// Whether every grep reads at least one of `files`, found by walking the directory `operand`, spelled `spelled` on the command line — or `nil` where that cannot be decided, git unable to read an ignore rule included.
    ///
    /// A file is read by every grep where no version-control name lies on its path below the operand, and either no `.gitignore` lies between the operand and it, or git, reading only the `.gitignore` files at or below the operand and matching case-sensitively, finds no pattern in them matching it, or finds that the last one is a `!` pattern and every `.gitignore` on its path is spelled plainly enough that `ugrep` reads it alike. A file with no `.gitignore` on its path settles it without git; git is asked only where there is none, once for all the rest.
    ///
    /// A pattern with a `/` inside it is read alike only in the operand's own `.gitignore` and only where the operand is spelled `.` or `./`, the one place the path `ugrep` matches it against is the path git does; anywhere else it is refused.
    static func readsOne(of files: [String], under operand: String, spelled: String) -> Bool? {
        guard !versionControlDirectories.contains((operand as NSString).lastPathComponent) else { return false }
        // The walk reports a path under the operand as the file system spells it (`/private/var` for `/var`).
        let prefixes = Set([operand, realpath(operand, nil).map { String(cString: $0) } ?? operand]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var underIgnoreFiles: [String] = []
        var holdsIgnoreFile: [String: Bool] = [:]
        var readings: [String: IgnoreReading] = [:]
        var sawRiskyIgnore = false
        var plainPath: [String: Bool] = [:]
        for file in files {
            guard let prefix = prefixes.first(where: file.hasPrefix) else { continue }
            let relative = String(file.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            guard !components.contains(where: versionControlDirectories.contains) else { continue }
            var directory = operand
            var ignoreFileOnPath = false
            var plain = true
            var directories = [operand]
            for component in components.dropLast() {
                directory = (directory as NSString).appendingPathComponent(component)
                directories.append(directory)
            }
            for candidate in directories where holds(candidate, &holdsIgnoreFile) {
                let reading = reading(candidate, pathsAlike: candidate == operand && [".", "./"].contains(spelled), &readings)
                // A file whose every line `ugrep` reads as matching nothing skips nothing.
                guard !reading.inert else { continue }
                ignoreFileOnPath = true
                // A `?` or a negated class takes one byte for git and one character for `ugrep`, so the two part only over a name that is not ASCII.
                sawRiskyIgnore = sawRiskyIgnore || reading.riskyAlways || reading.riskyByteWise && !relative.unicodeScalars.allSatisfy(\.isASCII)
                plain = plain && reading.plain
            }
            guard ignoreFileOnPath else { return true }
            underIgnoreFiles.append(relative)
            plainPath[relative] = plain
        }
        guard !underIgnoreFiles.isEmpty else { return false }
        guard !sawRiskyIgnore else { return nil }
        let directory = URL(fileURLWithPath: operand, isDirectory: true)
        guard let patterns = GitContext.lastMatchingIgnorePatterns(underIgnoreFiles, in: directory) else { return nil }
        return underIgnoreFiles.contains { file in
            guard let pattern = patterns[file] else { return false }
            return pattern.isEmpty || pattern.hasPrefix("!") && plainPath[file] == true
        }
    }

    /// Whether `directory` holds a `.gitignore`, asked of the disk once per directory.
    private static func holds(_ directory: String, _ known: inout [String: Bool]) -> Bool {
        if let answer = known[directory] {
            return answer
        }
        let answer = FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".gitignore"))
        known[directory] = answer
        return answer
    }

    /// How `directory`'s `.gitignore` reads, asked of the disk once per directory.
    ///
    /// It is risky where a line is one git's own ignore rules read differently from `ugrep`'s — a leading space or tab, a leading backslash before an ordinary character, a leading `./`, a trailing tab, vertical tab or form feed, a carriage return anywhere but last on the line, or a `?` or `[` spelled other than as `wildcards(in:)` models, since git reads some brackets that look closed as never closed; git drops the leading run, treats the whole line as a literal or keeps the trailing character, where `ugrep` trims or resolves it and still matches. A file that cannot be read, or is not UTF-8, is risky as a whole, since none of its lines can be checked. A pattern with a `/` inside it is risky too, unless git and `ugrep` match it against the same path. It is plain where every line is spelled plainly, and byte-wise where a line holds a `?` or a negated class, which git and `ugrep` read alike only over an ASCII name.
    private static func reading(_ directory: String, pathsAlike: Bool, _ known: inout [String: IgnoreReading]) -> IgnoreReading {
        if let answer = known[directory] {
            return answer
        }
        let path = (directory as NSString).appendingPathComponent(".gitignore")
        // A file that cannot be read, or is not UTF-8, is risky: none of its lines can be checked.
        var answer = IgnoreReading(riskyAlways: true, riskyByteWise: false, plain: false, inert: false)
        if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
            // Split on the scalar, not the character: a carriage return before it is part of the line, as it is to git.
            let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring(String(String.UnicodeScalarView($0))) }
            let risky = lines.contains(where: isRiskyIgnoreLine) || !pathsAlike && lines.contains(where: isPathShapedIgnoreLine)
            let byteWise = lines.contains { !$0.hasPrefix("#") && wildcards(in: $0).byteWise }
            let inert = lines.contains(where: isDeadIgnoreLine) && lines.allSatisfy { $0.isEmpty || $0 == "\r" || $0.hasPrefix("#") || isDeadIgnoreLine($0) }
            answer = IgnoreReading(riskyAlways: risky, riskyByteWise: byteWise, plain: lines.allSatisfy(isPlainIgnoreLine), inert: inert)
        }
        known[directory] = answer
        return answer
    }

    /// Whether one `.gitignore` line is spelled so plainly that git and `ugrep` are known to read it alike, a `!` pattern included.
    ///
    /// A blank line, a comment, or a pattern of printable ASCII with no backslash, no leading space and no bracket but the classes `wildcards(in:)` models, in which `**` stands only as a whole path segment. `ugrep` reads a POSIX class in brackets, or a `***`, as matching nothing where git matches, so a `!` pattern spelled so keeps a file for git that `ugrep` skips.
    private static func isPlainIgnoreLine(_ rawLine: Substring) -> Bool {
        // One carriage return closing the line is its CRLF ending: git drops it and `ugrep` trims it.
        let line = rawLine.unicodeScalars.last == "\r" ? Substring(String(String.UnicodeScalarView(rawLine.unicodeScalars.dropLast()))) : rawLine
        guard !line.isEmpty, !line.hasPrefix("#") else { return true }
        let body = line.hasPrefix("!") ? line.dropFirst() : line
        let printable = body.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) && $0 != "\\" }
        guard printable, !body.hasPrefix(" "), wildcards(in: body).alike else { return false }
        return hasOnlyWholeSegmentDoubleStars(body)
    }

    /// Whether every `**` in `body` stands as a whole path segment (`**` alone, or bounded by a `/` at either end where one is present) — the only shape git and `ugrep` read alike; glued to another character, `ugrep` lets it cross a `/` where git's `*` never does.
    private static func hasOnlyWholeSegmentDoubleStars(_ body: Substring) -> Bool {
        body.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.contains("**") || $0 == "**" }
    }

    /// Whether one `.gitignore` line is a pattern `ugrep` reads as matching nothing, where git matches with it: a `**` glued to a following character other than a `/`, as in `**Gen.swift`, `G?**.swift` or `a/**b.swift`.
    ///
    /// Measured against `ugrep` 7.8, such a line skips no path, wherever its `/` falls and whatever else the line holds; it is dead only where the rest is read alike, printable ASCII with no leading or trailing space, no backslash and no negation, since a `!` pattern of it keeps a path git keeps and `ugrep` may have skipped by another rule.
    private static func isDeadIgnoreLine(_ rawLine: Substring) -> Bool {
        let line = rawLine.unicodeScalars.last == "\r" ? Substring(String(String.UnicodeScalarView(rawLine.unicodeScalars.dropLast()))) : rawLine
        guard !line.hasPrefix("#"), !line.hasPrefix("!"), !line.hasPrefix(" "), !line.hasSuffix(" "), wildcards(in: line).alike else { return false }
        let scalars = Array(line.unicodeScalars)
        return scalars.indices.contains { index in
            guard index + 2 < scalars.count, scalars[index] == "*", scalars[index + 1] == "*" else { return false }
            return scalars[index + 2] != "*" && scalars[index + 2] != "/" && (index == 0 || scalars[index - 1] != "*")
        }
    }

    /// Whether one `.gitignore` line is a pattern with a `/` inside it — one not only leading and not only trailing — which git matches against the path from the `.gitignore`'s directory and `ugrep` against the path the walk spells from the operand.
    private static func isPathShapedIgnoreLine(_ line: Substring) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("#") else { return false }
        var body = line.drop { $0 == "\\" || $0 == "!" }
        body = body.dropLast(body.reversed().prefix { $0 == " " || $0 == "\r" }.count)
        body = body.hasSuffix("/") ? body.dropLast() : body
        body = body.hasPrefix("/") ? body.dropFirst() : body
        return body.contains("/")
    }

    /// Whether one `.gitignore` line is spelled so that git's ignore-pattern reading discards part of it, takes it literally or matches nothing with it, where `ugrep` still honours it as a pattern.
    private static func isRiskyIgnoreLine(_ rawLine: Substring) -> Bool {
        let line = String(rawLine)
        guard let first = line.first, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if first == " " || first == "\t" {
            return true
        }
        if first == "\\", let second = line.dropFirst().first, second != "!", second != "#" {
            return true
        }
        // git drops one carriage return, and only straight before the line feed, keeping any other as part of the pattern, where `ugrep` trims every trailing one.
        if line.unicodeScalars.dropLast(line.unicodeScalars.last == "\r" ? 1 : 0).contains("\r"), !line.hasPrefix("#") {
            return true
        }
        // git keeps a trailing tab, vertical tab or form feed as part of the pattern, where `ugrep` trims it.
        let untrimmed = line.unicodeScalars.reversed().drop { $0 == " " || $0 == "\r" }.first
        if let last = untrimmed, ["\t", "\u{0B}", "\u{0C}"].contains(last) {
            return true
        }
        // A `?` or a bracket is read alike only where it is spelled as `wildcards(in:)` models it.
        if line.contains(where: { $0 == "?" || $0 == "[" }), !line.hasPrefix("#"), !wildcards(in: rawLine).alike {
            return true
        }
        // `**` glued to another character in the same segment crosses a `/` for `ugrep` where git's `*` never does.
        if !hasOnlyWholeSegmentDoubleStars(rawLine.hasPrefix("!") ? rawLine.dropFirst() : rawLine) {
            return true
        }
        return line.hasPrefix("./")
    }

    /// Whether git and `ugrep` read the `?`, brackets and bracket classes of one `.gitignore` line alike, and whether it holds a `?` or a negated class, which match one byte for git and one character for `ugrep`.
    ///
    /// Read alike, as measured against `ugrep` 7.8: a line of printable ASCII with no backslash, whose every `[` opens a class closed by a `]`, optionally negated by a leading `!` or `^`, holding letters, digits, `.` and `_`, and ranges between two of those in ascending order, across letter cases included; a backslash before a `?` is a plain character; a `]` outside a class is not. git and `ugrep` part over a `]` straight after `[`, `[!` or `[^`, a backslash inside a class or before any other character, a `-` straight after a range, a `[` never closed and a POSIX class, and a character that is not ASCII is refused outright.
    private static func wildcards(in rawLine: Substring) -> (alike: Bool, byteWise: Bool) {
        let scalars = Array(rawLine.unicodeScalars.last == "\r" ? rawLine.unicodeScalars.dropLast() : rawLine.unicodeScalars[...])
        guard scalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) }) else { return (false, false) }
        let member: (Unicode.Scalar) -> Bool = { $0.properties.isAlphabetic || ("0" ... "9").contains($0) || $0 == "." || $0 == "_" }
        let kind: (Unicode.Scalar) -> Int? = { ("a" ... "z").contains($0) ? 0 : ("A" ... "Z").contains($0) ? 1 : ("0" ... "9").contains($0) ? 2 : nil }
        var byteWise = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\\" {
                // Outside a class, a backslash before `?` is a plain character both read alike; before anything else it is not modelled.
                guard index < scalars.count, scalars[index] == "?" else { return (false, byteWise) }
                index += 1
            } else if scalar == "?" {
                byteWise = true
            } else if scalar == "]" {
                return (false, byteWise)
            } else if scalar == "[" {
                if index < scalars.count, scalars[index] == "!" || scalars[index] == "^" {
                    byteWise = true
                    index += 1
                }
                var members = 0
                while index < scalars.count, scalars[index] != "]" {
                    let low = scalars[index]
                    guard member(low) else { return (false, byteWise) }
                    if index + 2 < scalars.count, scalars[index + 1] == "-" {
                        let high = scalars[index + 2]
                        guard kind(low) != nil, kind(high) != nil, low.value <= high.value else { return (false, byteWise) }
                        index += 2
                    }
                    index += 1
                    members += 1
                }
                guard index < scalars.count, members > 0 else { return (false, byteWise) }
                index += 1
            }
        }
        return (true, byteWise)
    }
}

/// How one directory's ignore file reads: whether git and `ugrep` part over a line of it, or over a name that is not ASCII only, whether every line is spelled plainly, and whether `ugrep` reads every line as matching nothing.
private extension UgrepSkips {
    struct IgnoreReading {
        let riskyAlways: Bool
        let riskyByteWise: Bool
        let plain: Bool
        let inert: Bool
    }
}
