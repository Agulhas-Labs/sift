//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines that write a symbol's name in the test files the build left out, which a semantic `where` lists beside its lower bound: `not in the build, mention the name: Tests/Fixtures/GizmoTests.swift:48,176 · Tests/Fixtures/GadgetTests.swift:408`.
///
/// The store records no occurrence in a file it holds no unit for, a test target the last build skipped or a file outside any target it builds, so a rename trusting the sweep misses those lines however honestly the count is called a lower bound. The files are the ones ``ZeroUseVerdict`` already classified, so nothing is recomputed, and none are read where no test build ran: every test file lacks a unit then, and the lower bound's build advice is the remedy. Each file is read once, as bytes, and searched for the name's bytes; only a file that holds them is lexed, once, by ``SwiftMentionLexer``, with no parse, and at most ``scanCap`` files are read, the rest counted as not scanned, so the line costs a bounded read of the outside files and nothing in a tree whose build holds every test file. A name is not a symbol: a mention is the name written as a whole word, `$name` and a backticked name included, never resolved, in code or in a string literal, which a rename has to look at too, but not in a comment. Every mentioning line is listed or counted in the closing marker, never dropped.
struct WhereUnbuiltMentions {
    /// Files listed one by one before the rest are only counted.
    static var fileCap: Int {
        10
    }

    /// Outside files read for mentions, the first in path order, before the rest are only counted as not scanned: the work is bounded by count, never by the clock, so the same tree gives the same answer.
    static var scanCap: Int {
        200
    }

    /// The line naming where `names` are written in the repo-relative `paths`, the test files no store holds a unit for: every file is searched for the name's bytes, the first `scanCap` in path order of those that hold them are lexed for their lines, and the rest that hold them are counted as not scanned; `nil` where none of them writes one.
    static func line(for names: ScannedNames, in paths: [String], under rootPath: String, scanCap: Int = WhereUnbuiltMentions.scanCap, listsEveryLine: Bool = false) -> String? {
        guard !names.isEmpty, !paths.isEmpty else { return nil }
        let scan = mentionScan(of: names, in: paths, under: rootPath, lexCap: scanCap)
        return line(listing: scan.mentions, unscanned: scan.unscanned, listsEveryLine: listsEveryLine)
    }

    /// Every line of the repo-relative `paths` that writes one of `names` as a whole word in the shape it is scanned for, outside a comment, ordered by path then line: each file read once as bytes and searched for each name's UTF-8 bytes, and lexed only where that search hits, so a stray byte that is not UTF-8 cannot hide the file.
    static func mentions(of names: ScannedNames, in paths: [String], under rootPath: String) -> [NameMention] {
        mentionScan(of: names, in: paths, under: rootPath, lexCap: Int.max).mentions
    }

    /// The mentions in the first files up to the lexing cap, in path order, whose bytes hold one of `names` as a whole word, and the number of such files past the cap, which were not lexed; files without the name are never counted, however many there are.
    static func mentionScan(of names: ScannedNames, in paths: [String], under rootPath: String, lexCap: Int) -> (mentions: [NameMention], unscanned: Int) {
        var found: [NameMention] = []
        var lexed = 0
        var unscanned = 0
        for path in paths.sorted() {
            guard let data = FileManager.default.contents(atPath: rootPath + "/" + path), names.writes(in: data) else { continue }
            guard lexed < lexCap else {
                unscanned += 1
                continue
            }
            lexed += 1
            let lines = data.withUnsafeBytes { names.hits(in: $0) }.filter { $0.place == .code || $0.place == .string }.map(\.line)
            found += Set(lines).sorted().map { NameMention(path: path, line: $0) }
        }
        return (found, unscanned)
    }

    /// The line for `mentions`, ordered by path then line, after `heading`: the first ``fileCap`` files with their lines, each capped at ``WhereRenderer/lineListCap`` with a count of the rest, then the files and lines past the cap counted (none past it in a `--refs` sweep, which lists every file and line), then the `unscanned` files no mention was looked for in, under the noun given for them; `nil` where there is nothing to say.
    static func line(
        listing mentions: [NameMention],
        unscanned: Int = 0,
        listsEveryLine: Bool = false,
        heading: String = "not in the build, mention the name: ",
        unscannedNoun: String = "outside file"
    ) -> String? {
        var paths: [String] = []
        var linesByPath: [String: [Int]] = [:]
        for mention in mentions {
            if linesByPath[mention.path] == nil {
                paths.append(mention.path)
            }
            linesByPath[mention.path, default: []].append(mention.line)
        }
        guard !paths.isEmpty || unscanned > 0 else { return nil }
        let fileLimit = listsEveryLine ? Int.max : fileCap
        let lineLimit = listsEveryLine ? Int.max : WhereRenderer.lineListCap
        var entries = paths.isEmpty ? ["none in the files scanned"] : paths.prefix(fileLimit).map { path in
            let lines = linesByPath[path] ?? []
            var entry = "\(path):" + lines.prefix(lineLimit).map(String.init).joined(separator: ",")
            if lines.count > lineLimit {
                entry += ", +\(lines.count - lineLimit) more"
            }
            return entry
        }
        let hidden = paths.dropFirst(fileLimit)
        if !hidden.isEmpty {
            let hiddenLines = hidden.reduce(0) { $0 + (linesByPath[$1]?.count ?? 0) }
            entries.append("… \(hidden.count) more file\(hidden.count == 1 ? "" : "s"), \(hiddenLines) line\(hiddenLines == 1 ? "" : "s")")
        }
        if unscanned > 0 {
            entries.append("\(unscanned) \(unscannedNoun)\(unscanned == 1 ? "" : "s") not scanned")
        }
        return heading + entries.joined(separator: " · ")
    }
}
