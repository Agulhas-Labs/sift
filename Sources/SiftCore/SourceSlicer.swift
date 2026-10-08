//
// Copyright © Agulhas Labs
//

import Foundation
import SwiftSyntax

/// Slices declaration heads and doc summaries out of original source bytes.
///
/// Signatures are source slices, not syntax-node reconstructions: reconstruction loses exactly the things Swift 6 work needs visible (`@MainActor`, `nonisolated`, `async`, `throws`, `some`/`any`, availability). Slicing cannot (Docs/Design.md §2).
struct SourceSlicer {
    /// A symbol's current source lines, read from disk at query time.
    ///
    /// Shared by `digest Type.member` and the compression-floor passthrough, which would otherwise each carry a copy of this read-split-clamp-guard sequence, free to diverge on capping. Both serve *current* source rather than anything stored, so neither can be answered from the index alone.
    static func slice(of row: SymbolRow, under repoRoot: URL) -> Slice {
        slice(of: row, in: try? String(contentsOf: repoRoot.appendingPathComponent(row.path), encoding: .utf8))
    }

    /// The same slice out of `source`, the row's file already read (`nil` when it could not be).
    static func slice(of row: SymbolRow, in source: String?) -> Slice {
        slice(line: row.line, endLine: row.endLine, in: source)
    }

    /// The same read for a range no row holds, such as a `deinit`, which the index never stores.
    static func slice(path: String, line: Int, endLine: Int, under repoRoot: URL) -> Slice {
        slice(line: line, endLine: endLine, in: try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }

    /// Lines `line` through `endLine` of `source` (`nil` when the file could not be read).
    private static func slice(line: Int, endLine: Int, in source: String?) -> Slice {
        guard let source else {
            return .unreadable
        }
        let sourceLines = source.components(separatedBy: "\n")
        let start = max(line - 1, 0)
        let end = min(endLine, sourceLines.count)
        guard start < end else {
            return .emptyRange
        }
        return .lines(Array(sourceLines[start ..< end]), firstLineNumber: start + 1)
    }

    /// The length a displayed signature is cut at.
    static var signatureCap: Int {
        200
    }

    /// The source text between two absolute positions, whitespace-collapsed and cut at `cap` characters — or whole, for text that is compared rather than shown.
    static func collapsedSlice(of sourceBytes: [UInt8], from start: AbsolutePosition, to end: AbsolutePosition, cap: Int? = signatureCap) -> String {
        guard start.utf8Offset >= 0, end.utf8Offset <= sourceBytes.count, start.utf8Offset < end.utf8Offset else {
            return ""
        }
        guard let raw = String(bytes: sourceBytes[start.utf8Offset ..< end.utf8Offset], encoding: .utf8) else {
            return ""
        }
        let collapsed = collapsingWhitespace(in: raw)
        guard let cap else { return collapsed }
        return cut(collapsed, at: cap)
    }

    /// `text` with each run of whitespace outside a string literal reduced to one space and the ends trimmed; a literal's own contents, multi-line and raw ones included, are kept exactly, because a default of four spaces is not a default of one.
    static func collapsingWhitespace(in text: String) -> String {
        let chars = Array(text)
        var out = ""
        var pendingSpace = false
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                pendingSpace = !out.isEmpty
                index += 1
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            let end = literalEnd(in: chars, from: index)
            out.append(contentsOf: chars[index ..< end])
            index = end
        }
        return out
    }

    /// The index just past the string or extended regex (`#/…/#`) literal that opens at `start`, or past the one character at `start` where none does.
    ///
    /// A bare `/…/` regex is not read: in a signature it cannot be told from a division.
    private static func literalEnd(in chars: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < chars.count, chars[cursor] == "#" {
            cursor += 1
        }
        let hashes = cursor - start
        if hashes > 0, cursor < chars.count, chars[cursor] == "/" {
            return regexEnd(in: chars, from: cursor + 1, hashes: hashes)
        }
        guard cursor < chars.count, chars[cursor] == "\"" else { return start + 1 }
        var quotes = 0
        while cursor + quotes < chars.count, chars[cursor + quotes] == "\"", quotes < 3 {
            quotes += 1
        }
        // `""` is an empty literal, not the opener of a multi-line one.
        let delimiter = quotes == 3 ? 3 : 1
        cursor += delimiter
        while cursor < chars.count {
            if chars[cursor] == "\\", cursor + 1 + hashes <= chars.count, chars[(cursor + 1) ..< (cursor + 1 + hashes)].allSatisfy({ $0 == "#" }) {
                cursor += hashes + 2
                continue
            }
            if chars[cursor] == "\"",
               cursor + delimiter + hashes <= chars.count,
               chars[cursor ..< cursor + delimiter].allSatisfy({ $0 == "\"" }),
               chars[(cursor + delimiter) ..< (cursor + delimiter + hashes)].allSatisfy({ $0 == "#" })
            {
                return cursor + delimiter + hashes
            }
            cursor += 1
        }
        return chars.count
    }

    /// The index just past the `/` and `hashes` hashes that close an extended regex literal whose body starts at `start`; a backslash escapes the character after it.
    private static func regexEnd(in chars: [Character], from start: Int, hashes: Int) -> Int {
        var cursor = start
        while cursor < chars.count {
            if chars[cursor] == "\\" {
                cursor += 2
                continue
            }
            if chars[cursor] == "/", cursor + 1 + hashes <= chars.count, chars[(cursor + 1) ..< (cursor + 1 + hashes)].allSatisfy({ $0 == "#" }) {
                return cursor + 1 + hashes
            }
            cursor += 1
        }
        return chars.count
    }

    /// A stored signature as every answer prints it: the space a collapsed line break left just inside a bracket removed, and the result cut at `signatureCap`.
    static func shown(_ signature: String) -> String {
        cut(tidyingBrackets(in: signature), at: signatureCap)
    }

    /// `text` without a space just after `(` or `[` or just before `)` or `]`, outside string literals.
    ///
    /// The stored text has one space where the source broke the line (`answer(` then `_ call:`), and cannot tell that from a space written there, so any such space goes. A space between a name and `(` (`-> (Int)`), and a literal's contents, are never touched.
    static func tidyingBrackets(in text: String) -> String {
        let chars = Array(text)
        var out = ""
        var index = 0
        while index < chars.count {
            let end = literalEnd(in: chars, from: index)
            if end - index > 1 {
                out.append(contentsOf: chars[index ..< end])
                index = end
                continue
            }
            let char = chars[index]
            index += 1
            if char == " ", let last = out.last, "([".contains(last) || (index < chars.count && ")]".contains(chars[index])) {
                continue
            }
            out.append(char)
        }
        return out
    }

    /// `text` cut to `cap` characters, the last of them an ellipsis when anything was cut.
    static func cut(_ text: String, at cap: Int) -> String {
        text.count > cap ? String(text.prefix(cap - 1)) + "…" : text
    }

    /// The first line of the declaration's doc comment, or `nil` when it has none.
    static func docSummary(from trivia: Trivia) -> String? {
        for piece in trivia {
            switch piece {
            case let .docLineComment(text):
                let stripped = text
                    .replacingOccurrences(of: "///", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty {
                    continue
                }
                return cap(stripped)
            case let .docBlockComment(text):
                let body = text
                    .replacingOccurrences(of: "/**", with: "")
                    .replacingOccurrences(of: "*/", with: "")
                let firstLine = body
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                guard let firstLine else { continue }
                return cap(firstLine)
            default:
                continue
            }
        }
        return nil
    }

    /// Caps a doc summary at roughly this many UTF-8 bytes — the unit the digest-to-source ratio these summaries feed into is itself measured in (`SourcePassthrough`), so an em dash — three bytes to one `Character` — is charged what it actually costs, not what counting characters would say.
    private static let summaryLimit = 80

    /// The most a summary ever costs, in the same bytes, marker included — the bound on a run with no word boundary anywhere near `summaryLimit`, which has nowhere safe to be cut.
    private static let summaryCeiling = 160

    /// Punctuation worth cutting a summary at rather than an arbitrary byte offset — the marks that end a clause in this repo's own prose.
    ///
    /// A mark ends a clause only when whitespace follows it and it sits outside a code span (`cap(_:)`): the dot in `Type.member` and the colons in `save(_:to:)` sit inside an identifier, and cutting there serves half a name.
    private static let clauseBoundaries: Set<Character> = [",", ";", ":", ".", "—"]

    /// Abbreviations whose own period reads, to `cap(_:)`, exactly like a sentence's: whitespace follows it and it sits outside a code span.
    ///
    /// Checked before any mark is taken as a clause boundary, so a summary is never cut as "e.g…" — nor as "e.g.,…", where the comma written straight after the abbreviation is followed by the whitespace its period is not.
    private static let abbreviations = ["e.g.", "i.e."]

    /// Whether the mark at `index` ends one of `abbreviations` rather than a clause: the abbreviation's own period, or a mark written straight after it.
    private static func endsAbbreviation(_ text: String, at index: String.Index) -> Bool {
        if text[index] == ".", closesAbbreviation(text, at: index) {
            return true
        }
        guard index > text.startIndex else { return false }
        let previous = text.index(before: index)
        return text[previous] == "." && closesAbbreviation(text, at: previous)
    }

    /// Whether the `.` at `index` closes one of `abbreviations` rather than a sentence.
    private static func closesAbbreviation(_ text: String, at index: String.Index) -> Bool {
        abbreviations.contains { abbreviation in
            guard let start = text.index(index, offsetBy: -(abbreviation.count - 1), limitedBy: text.startIndex) else { return false }
            return text[start ... index].lowercased() == abbreviation
        }
    }

    /// What marks a cut summary, in place of whatever was cut.
    private static var cutMarker: String {
        "…"
    }

    /// Cuts `text` to `summaryLimit` bytes at a clause boundary when one keeps at least half the budget, else at the last word boundary, and never mid-word below `summaryCeiling`.
    ///
    /// A boundary a few bytes into an eighty-byte sentence is a worse answer than the plain word it left on the table, which is why a clause cut has to clear half the budget before it is preferred over a word cut nearer the end. A word boundary outside a code span is preferred on the same terms, so a cut leaves a backtick open only where nothing better keeps half the budget.
    ///
    /// A summary whose first `summaryLimit` bytes hold no word boundary at all — one long unbroken run — is cut at the first one after them instead, and served whole when it has none and fits `summaryCeiling`. Past the ceiling it is cut there, mid-word and marked: the one place a word is broken, because the alternative is a summary with no bound at all.
    private static func cap(_ text: String) -> String {
        guard text.utf8.count > summaryLimit else { return text }
        let window = byteBoundedPrefix(of: text, maxBytes: summaryLimit)
        let minimumKept = summaryLimit / 2
        var insideCode = false
        var clauseCut: String.Index?
        var wordCutOutsideCode: String.Index?
        var wordCut: String.Index?
        for index in window.indices {
            let character = window[index]
            if character == "`" {
                insideCode.toggle()
                continue
            }
            if character.isWhitespace {
                wordCut = index
                if !insideCode {
                    wordCutOutsideCode = index
                }
            }
            let following = text.index(after: index)
            if !insideCode, clauseBoundaries.contains(character), following < text.endIndex, text[following].isWhitespace,
               !endsAbbreviation(text, at: index)
            {
                clauseCut = index
            }
        }
        for cut in [clauseCut, wordCutOutsideCode] {
            if let cut, let kept = kept(window, before: cut), kept.utf8.count >= minimumKept {
                return kept + cutMarker
            }
        }
        if let cut = wordCut, let kept = kept(window, before: cut) {
            return kept + cutMarker
        }
        return unbrokenRunCut(text)
    }

    /// The text before `cut`, trimmed, or `nil` when nothing is left.
    private static func kept(_ window: Substring, before cut: String.Index) -> String? {
        let kept = window[window.startIndex ..< cut].trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    /// The cut for a summary with no word boundary in its first `summaryLimit` bytes: the first one after them within `summaryCeiling`, else the whole summary where it fits, else the ceiling itself.
    private static func unbrokenRunCut(_ text: String) -> String {
        let room = summaryCeiling - cutMarker.utf8.count
        let reach = byteBoundedPrefix(of: text, maxBytes: room)
        if let cut = reach.indices.first(where: { reach[$0].isWhitespace }), let kept = kept(reach, before: cut) {
            return kept + cutMarker
        }
        guard text.utf8.count > summaryCeiling else { return text }
        return String(reach) + cutMarker
    }

    /// The longest prefix of `text` whose UTF-8 encoding is at most the given byte budget, breaking only between whole `Character`s so a multi-byte grapheme is never split.
    private static func byteBoundedPrefix(of text: String, maxBytes: Int) -> Substring {
        var end = text.startIndex
        var bytes = 0
        for index in text.indices {
            let next = bytes + String(text[index]).utf8.count
            guard next <= maxBytes else { break }
            bytes = next
            end = text.index(after: index)
        }
        return text[..<end]
    }
}

extension SourceSlicer {
    /// The three outcomes of slicing a symbol's source out of the file on disk.
    enum Slice {
        /// The file could not be read.
        case unreadable
        /// The indexed range covers no lines in the file as it currently stands.
        case emptyRange
        /// The symbol's lines, with the 1-based line number the first of them occupies.
        case lines([String], firstLineNumber: Int)
    }
}
