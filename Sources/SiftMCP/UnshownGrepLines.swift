//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The matching lines a grep prints that a `where` answer standing in for it does not show: comments, which no index records, and any other line no site accounts for.
///
/// Counted so that the answer says what it leaves out: a line the search would print is shown or counted, never dropped in silence. Where what the search prints cannot be known, the answer says the lines went uncounted (``notCounted``) rather than counting nothing.
struct UnshownGrepLines: Equatable {
    /// Matching lines that hold only a comment.
    let comments: Int
    /// Every other matching line the answer does not show.
    let others: Int
    /// Matching lines the answer's per-file cap cut from a file's list of sites: sites it recognised, not lines no site accounts for.
    let cut: Int

    /// The line an answer carries where the lines its search prints could not be counted: a `Grep`, which runs no search here, one whose files cannot all be read alike, one past the print limit, or one cut where the order of what it prints is unfixed.
    static var notCounted: String {
        "other matching lines (comments, text) were not counted — re-run the identical command to see them"
    }

    /// The extensions of the files whose lines are read as code that comments can stand on: Swift's and the C family's, which share its comment syntax.
    ///
    /// A line of any other file is never a comment here (a Markdown bullet opens on `*` too).
    private static let commentingExtensions: Set<String> = ["swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hh", "hpp"]

    /// The lines counted as given.
    init(comments: Int, others: Int, cut: Int = 0) {
        self.comments = comments
        self.others = others
        self.cut = cut
    }

    /// The distinct matching lines of `printed` the answer does not show, read from the files as `directory` resolves them: neither a site in `shown` nor a doc comment line whose summary `answer` shows beside its declaration.
    ///
    /// A line grep prints twice, under two operands one of which holds the other, is one line and counted once.
    ///
    /// A line in `cutSites` is a site the answer's per-file cap cut, counted apart from a line no site accounts for.
    init(_ printed: [ShellGrep.PrintedLine], shown: Set<ExactAnswer.Location>, cutSites: Set<ExactAnswer.Location> = [], answer: String, from directory: String?, in engine: SiftEngine) {
        let summaries = ExactAnswer.docSummaries(inWhereAnswer: answer)
        var comments = 0
        var others = 0
        var cut = 0
        var counted = Set<String>()
        var sources: [String: [Substring]] = [:]
        for line in printed where line.matched {
            let file = OperandFile.absolute(line.file, in: directory) ?? line.file
            let relative = ExactAnswer.repositoryRelativePath(of: file, in: engine)
            guard counted.insert("\(relative ?? file):\(line.line)").inserted else { continue }
            if let relative, shown.contains(ExactAnswer.Location(path: relative, line: line.line)) {
                continue
            }
            if sources[file] == nil {
                sources[file] = (try? String(contentsOfFile: file, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            }
            let text = sources[file].flatMap { line.line >= 1 && line.line <= $0.count ? $0[line.line - 1] : nil }
            if let relative, cutSites.contains(ExactAnswer.Location(path: relative, line: line.line)) {
                cut += 1
                continue
            }
            guard let text, Self.readsComments(file), Self.isComment(text) else {
                others += 1
                continue
            }
            let summary = Self.docText(text)
            let lines = sources[file] ?? []
            guard !summaries.contains(where: { $0.declaration.path == relative && $0.summary == summary && Self.docRun(above: $0.declaration.line, in: lines, holds: line.line) }) else { continue }
            comments += 1
        }
        self.comments = comments
        self.others = others
        self.cut = cut
    }

    /// `printed` where it is every line the search prints, or `nil` where that is not known: `bytes` is what the search was weighed at (``InPlaceAnswerer``), `nil` for one that ran no search and `Int.max` for one stopped past its print limit, and a `cut` that does not keep every line handed back has them as every line any order could print, not the lines it keeps.
    static func counted(_ printed: [ShellGrep.PrintedLine], weighed bytes: Int?, cut: ShellGrep.Cut?) -> [ShellGrep.PrintedLine]? {
        guard let bytes, bytes != .max, cut?.keepsAll(of: printed.count) ?? true else { return nil }
        return printed
    }

    /// Whether lines of the file at `path` can be comments: a Swift or C-family source.
    static func readsComments(_ path: String) -> Bool {
        commentingExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Whether `text` holds a comment and nothing else: a line or doc comment, a block comment's opening, or a block comment's continuation.
    static func isComment(_ text: some StringProtocol) -> Bool {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    /// Whether `line` is in the doc comment directly above the declaration opening on `declaration`: the unbroken run of comment and attribute lines `lines` holds above it.
    private static func docRun(above declaration: Int, in lines: [Substring], holds line: Int) -> Bool {
        var current = min(declaration, lines.count + 1) - 1
        while current >= 1 {
            if current == line {
                return true
            }
            let text = lines[current - 1]
            guard isComment(text) || text.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("@") else { return false }
            current -= 1
        }
        return false
    }

    /// A doc comment line's text as a doc summary reads it: its `///` or `/**` and any closing `*/` dropped, trimmed.
    private static func docText(_ text: some StringProtocol) -> String {
        var body = Substring(text).drop { $0 == " " || $0 == "\t" }
        for opening in ["///", "/**"] where body.hasPrefix(opening) {
            body = body.dropFirst(opening.count)
        }
        if body.hasSuffix("*/") {
            body = body.dropLast(2)
        }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// The line an answer carries naming what it does not show under `paths`, or `nil` where it shows every matching line.
    func note(under paths: [String]) -> String? {
        let place = paths.isEmpty ? "in the search" : "under " + paths.joined(separator: " ")
        let counted = [
            comments > 0 ? "\(comments) comment line\(comments == 1 ? "" : "s")" : nil,
            cut > 0 ? "\(cut) more site\(cut == 1 ? "" : "s") past the per-file cap" : nil,
            others > 0 ? "\(others) other line\(others == 1 ? "" : "s") no site accounts for" : nil,
        ].compactMap(\.self)
        guard !counted.isEmpty else { return nil }
        let verb = comments + others + cut == 1 ? "matches" : "match"
        return "\(counted.joined(separator: " and ")) \(place) also \(verb), not shown here — re-run the identical command to see them"
    }
}
