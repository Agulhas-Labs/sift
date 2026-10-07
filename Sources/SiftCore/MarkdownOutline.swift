//
// Copyright © Agulhas Labs
//

import Foundation

/// A Markdown document's heading outline — the sections a `digest <file>.md` locates by, read from the text and never stored (Docs/Design.md §3).
///
/// Headings only. Nothing here reads prose, and nothing it finds reaches the index: the answer is a table of contents with line ranges, so the read that follows is a ranged one, exactly as a Swift digest's member ranges make it.
///
/// **ATX headings only** — `#` to `######` at the start of a line. Setext headings (a line underlined with `===` or `---`) are not recognised: the underline is also how a horizontal rule and a table are written, and a heading claimed where there is none puts a section boundary in the middle of a paragraph, which is worse than missing one.
public struct MarkdownOutline {
    /// The most `#`s a heading may carry; a seventh is not a heading at all.
    private static let deepestLevel = 6

    /// The most a heading or a fence may be indented before it stops being one — four spaces begin a code block.
    private static let deepestIndent = 3

    /// Whether `path` names a Markdown file, by its extension alone and case-insensitively.
    ///
    /// The extension is the whole of the test on purpose: what a `.md` target is served is read live from disk, so there is nothing stored to consult about it and nothing to guess at.
    ///
    /// The one part of this type another module can see, because the advice hook has to decide "is this a document `digest` answers" by the *same* test the renderer routes on (``ReadAdvice``, ``DigestFloor``): a second spelling of the extension rule would send a caller to a call that resolved as a type name instead.
    public static func names(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".md")
    }

    /// Every heading in `lines`, each with the section it opens.
    static func sections(of lines: [String]) -> [Section] {
        var found: [Opening] = []
        var fence: (character: Character, length: Int)?
        let skipped = frontMatterLength(of: lines)
        for (index, line) in lines.enumerated() where index >= skipped {
            // A CRLF document's lines still end in `\r` once split on `\n`; without this the return would sit
            // inside every title and stand between a closing run of `#`s and the rule that strips it.
            guard let body = undented(line.hasSuffix("\r") ? String(line.dropLast()) : line) else { continue }
            if let open = fence {
                if closes(open, body) {
                    fence = nil
                }
                continue
            }
            if let opened = opening(fence: body) {
                fence = opened
                continue
            }
            if let heading = heading(body) {
                found.append(Opening(level: heading.level, title: heading.title, start: index + 1))
            }
        }
        return found.enumerated().map { position, heading in
            let next = found[(position + 1)...].first { $0.level <= heading.level }
            return Section(
                level: heading.level,
                title: heading.title,
                start: heading.start,
                end: (next?.start ?? lines.count + 1) - 1
            )
        }
    }

    /// How many lines open `lines` as a front-matter block, or 0 where none does.
    ///
    /// A block opens only on line 1, exactly `---`, and closes on the next line that is exactly `---` or `...`; a block never closed is not front matter, so a document that opens with a thematic break is read as before. Its lines are YAML, where `#` begins a comment, so none of them is scanned for headings.
    private static func frontMatterLength(of lines: [String]) -> Int {
        func bare(_ line: String) -> String {
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        guard let first = lines.first, bare(first) == "---" else { return 0 }
        for index in lines.indices.dropFirst() where ["---", "..."].contains(bare(lines[index])) {
            return index + 1
        }
        return 0
    }

    /// `line` with its leading spaces removed, or `nil` when it carries more than Markdown allows before a heading or a fence.
    private static func undented(_ line: String) -> Substring? {
        let body = line.drop { $0 == " " }
        return line.count - body.count <= deepestIndent ? body : nil
    }

    /// Every top-level bullet in `lines`, each attached to the heading whose immediate body it sits in.
    ///
    /// A section that runs 1,200 lines under one heading is still one row in the outline unless its own content is broken out — this is that break-out.
    ///
    /// Only an unindented `-`/`*`/`+` marker counts as top-level: a sub-bullet, indented beneath its parent, is read as part of the item that already located it, not a locating step of its own. A bullet ahead of the first heading has nothing to attach to and is dropped.
    static func bullets(of lines: [String]) -> [Bullet] {
        var openings: [Int] = []
        var items: [BulletOpening] = []
        var currentHeadingStart: Int?
        var fence: (character: Character, length: Int)?
        let skipped = frontMatterLength(of: lines)
        for (index, line) in lines.enumerated() where index >= skipped {
            let raw = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let body = undented(raw) else { continue }
            if let open = fence {
                if closes(open, body) {
                    fence = nil
                }
                continue
            }
            if let opened = opening(fence: body) {
                fence = opened
                continue
            }
            if heading(body) != nil {
                openings.append(index + 1)
                currentHeadingStart = index + 1
                continue
            }
            guard let marker = raw.first, marker == "-" || marker == "*" || marker == "+",
                  raw.count > 1, raw[raw.index(after: raw.startIndex)] == " ",
                  let headingStart = currentHeadingStart
            else { continue }
            openings.append(index + 1)
            items.append(BulletOpening(start: index + 1, text: raw.dropFirst(2), headingStart: headingStart))
        }
        return items.map { item in
            let end = (openings.first { $0 > item.start } ?? lines.count + 1) - 1
            let text = item.text.trimmingCharacters(in: .whitespaces)
            return Bullet(
                title: bulletTitle(of: text),
                start: item.start,
                end: end,
                struck: text.hasPrefix("~~"),
                section: item.headingStart
            )
        }
    }

    /// A bullet's leading bold run, or where it has none, its first dozen words.
    private static func bulletTitle(of text: String) -> String {
        boldRun(in: text) ?? firstWords(of: text, max: 12)
    }

    /// The text inside a `**bold**` run at the start of `text`, or `nil` where it opens with none.
    private static func boldRun(in text: String) -> String? {
        guard let opensAt = text.range(of: "**") else { return nil }
        let rest = text[opensAt.upperBound...]
        guard let closesAt = rest.range(of: "**") else { return nil }
        let inner = rest[rest.startIndex ..< closesAt.lowerBound].trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// The first `max` whitespace-separated words of `text`, marked with `…` where more follow.
    private static func firstWords(of text: String, max: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let kept = words.prefix(max).joined(separator: " ")
        return words.count > max ? "\(kept)…" : kept
    }

    /// The fence `body` opens, or `nil` where it opens none.
    ///
    /// A backtick fence's info string may not itself hold a backtick, which is what keeps a paragraph that quotes ```` ``` ```` inline from swallowing the rest of the document.
    private static func opening(fence body: Substring) -> (character: Character, length: Int)? {
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let length = body.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        guard character == "~" || !body.dropFirst(length).contains("`") else { return nil }
        return (character, length)
    }

    /// Whether `body` closes `open`: the same character, at least as long, and nothing after it but whitespace.
    ///
    /// A fence that is never closed runs to the end of the file, so every `#` beneath it stays code — which is the reading a truncated transcript or an unfinished example needs.
    private static func closes(_ open: (character: Character, length: Int), _ body: Substring) -> Bool {
        let length = body.prefix { $0 == open.character }.count
        return length >= open.length && body.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    /// The heading `body` is, or `nil` where it is not one.
    private static func heading(_ body: Substring) -> (level: Int, title: String)? {
        let level = body.prefix { $0 == "#" }.count
        guard level >= 1, level <= deepestLevel else { return nil }
        let rest = body.dropFirst(level)
        // The space is required: `#hashtag` is a paragraph, not a heading.
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (level, title(of: rest))
    }

    /// A heading's text, with the optional closing run of `#`s stripped — `## Scope ##` is titled `Scope`.
    ///
    /// The run closes the heading only where a space precedes it or it is the whole of the text; `## C#` keeps its name.
    private static func title(of rest: Substring) -> String {
        let text = rest.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix { $0 == "#" }.count
        guard closing > 0 else { return text }
        let head = text.dropLast(closing)
        guard head.isEmpty || head.last == " " || head.last == "\t" else { return text }
        return head.trimmingCharacters(in: .whitespaces)
    }
}

extension MarkdownOutline {
    /// One heading and the span it opens, in 1-based file lines.
    ///
    /// A section runs from its heading to the line before the next heading of the same or a shallower level, so a `##` section contains its `###`s, and the last one runs to the end of the file.
    struct Section: Equatable {
        let level: Int
        let title: String
        let start: Int
        let end: Int
    }

    /// One top-level bullet, its own span (through any continuation lines and sub-bullets it carries), and the heading it sits directly under.
    struct Bullet: Equatable {
        let title: String
        let start: Int
        let end: Int
        let struck: Bool
        let section: Int
    }
}

private extension MarkdownOutline {
    /// A heading met on the way down the document, before the section it opens has an end: every end is settled by the heading that follows it, so none of them is known until the walk is over.
    struct Opening {
        let level: Int
        let title: String
        let start: Int
    }

    /// A top-level bullet met on the way down the document, before its own end (the next bullet or heading) is known.
    struct BulletOpening {
        let start: Int
        let text: Substring
        let headingStart: Int
    }
}
