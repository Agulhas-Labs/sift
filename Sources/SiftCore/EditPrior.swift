//
// Copyright © Agulhas Labs
//

/// What a file held before the edit the `PostToolUse` hook is checking, as far as the hook's payload tells it.
///
/// The parse check reports only the errors an edit added, so a file broken on purpose is not blocked on every edit of it; this is what it compares against.
public enum EditPrior: Sendable, Equatable {
    /// The payload does not say, so every error the file has is reported as the edit's.
    case unknown
    /// The file's content before the edit, empty for a file the edit created.
    case content(String)
    /// The hunks the edit applied, to be undone against the content it left.
    case patch([Hunk])

    /// The content before the edit, given `current`, the content it left; `nil` where that cannot be told, including a patch that does not match `current`.
    ///
    /// Claude Code folds `"\r\n"` to `"\n"` as it reads a file, so the original and the patch it sends are LF throughout, and writes the edit back in the file's majority line ending. So the patch is undone against `current` folded to LF, and where most of `current`'s line breaks are `"\r\n"` the content before the edit is given them too, as it read on disk.
    public func source(before current: String) -> String? {
        let prior: String? = switch self {
        case .unknown:
            nil
        case let .content(prior):
            prior
        case let .patch(hunks):
            Self.undoneAgainstTabsAsSpaces(hunks, on: Self.foldedToLF(current))
        }
        guard let prior, Self.breaksMostlyAtCRLF(current) else { return prior }
        return Self.lines(of: Self.foldedToLF(prior)).joined(separator: "\r\n")
    }

    /// Whether more of `text`'s line breaks are `"\r\n"` than a lone `"\n"`, the test Claude Code writes an edit back by.
    static func breaksMostlyAtCRLF(_ text: String) -> Bool {
        let broken = lines(of: text).dropLast()
        let crlf = broken.count { $0.unicodeScalars.last == "\r" }
        return crlf > broken.count - crlf
    }

    /// `text` with each `"\r\n"` made `"\n"`, as Claude Code reads a file; a `"\r"` no `"\n"` follows is kept.
    static func foldedToLF(_ text: String) -> String {
        var lines = lines(of: text)
        for index in lines.indices.dropLast() where lines[index].unicodeScalars.last == "\r" {
            lines[index] = String(String.UnicodeScalarView(lines[index].unicodeScalars.dropLast()))
        }
        return lines.joined(separator: "\n")
    }

    /// `text` split at each `"\n"` and nowhere else, so a `"\r\n"` file keeps its `"\r"` on the line and joining the lines with `"\n"` gives `text` back.
    ///
    /// `String.split` works on characters, where `"\r\n"` is one that is not `"\n"`.
    static func lines(of text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// `current` with each hunk undone as it is, or, where that does not match, against a copy of `current` with each leading tab made two spaces.
    ///
    /// Claude Code makes each leading tab of a patch line two spaces, so the patch of a tab-indented file does not match the file as it is. The lines of the content before the edit that `current` holds keep their real indentation; a removed line, which only the patch holds, has its leading spaces turned back into tabs, two to a tab.
    private static func undoneAgainstTabsAsSpaces(_ hunks: [Hunk], on current: String) -> String? {
        undo(hunks, on: current) ?? undo(hunks, on: current, converted: true)
    }

    /// `text` with each tab before its first other character made two spaces, as Claude Code writes a patch line.
    static func leadingTabsAsSpaces(_ text: String) -> String {
        let tabs = text.prefix { $0 == "\t" }.count
        return String(repeating: "  ", count: tabs) + text.dropFirst(tabs)
    }

    /// `text` with each two spaces before its first other character made a tab, the reverse of ``leadingTabsAsSpaces(_:)`` where the indentation was tabs; a single space left over is kept.
    static func leadingSpacesAsTabs(_ text: String) -> String {
        let spaces = text.prefix { $0 == " " }.count
        return String(repeating: "\t", count: spaces / 2) + String(repeating: " ", count: spaces % 2) + text.dropFirst(spaces)
    }

    /// `current` with each hunk undone: its `' '` and `'+'` lines checked against `current` and replaced by its `' '` and `'-'` lines, or `nil` at the first line that does not match.
    ///
    /// With `converted` the lines are checked as `leadingTabsAsSpaces(_:)` makes them, and the lines kept are `current`'s own.
    private static func undo(_ hunks: [Hunk], on current: String, converted: Bool = false) -> String? {
        let lines = Self.lines(of: current)
        var prior: [String] = []
        var cursor = 0
        for hunk in hunks {
            let start = max(hunk.newStart - 1, 0)
            guard start >= cursor, start <= lines.count else { return nil }
            prior += lines[cursor ..< start]
            cursor = start
            for line in hunk.lines {
                let text = String(line.dropFirst())
                switch line.first {
                case " ", "+":
                    guard cursor < lines.count else { return nil }
                    let real = lines[cursor]
                    guard (converted ? leadingTabsAsSpaces(real) : real) == text else { return nil }
                    cursor += 1
                    if line.first == " " {
                        prior.append(real)
                    }
                case "-":
                    prior.append(converted ? leadingSpacesAsTabs(text) : text)
                case "\\":
                    continue
                default:
                    return nil
                }
            }
        }
        prior += lines[cursor...]
        return prior.joined(separator: "\n")
    }
}

public extension EditPrior {
    /// One hunk of the edit's patch: where it starts in the content before and after the edit, and its lines, each marked `' '`, `'-'` or `'+'`.
    struct Hunk: Sendable, Equatable {
        /// The 1-based line the hunk starts at in the content before the edit.
        public let oldStart: Int
        /// The 1-based line the hunk starts at in the content the edit left.
        public let newStart: Int
        /// The hunk's lines, each prefixed by its marker.
        public let lines: [String]

        public init(oldStart: Int, newStart: Int, lines: [String]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }

        /// The lines the hunk covers in the content the edit left: its context and added lines.
        var newRange: Range<Int> {
            newStart ..< newStart + lines.count { $0.first == " " || $0.first == "+" }
        }

        /// The lines the hunk covers in the content before the edit: its context and removed lines.
        var oldRange: Range<Int> {
            oldStart ..< oldStart + lines.count { $0.first == " " || $0.first == "-" }
        }
    }
}
