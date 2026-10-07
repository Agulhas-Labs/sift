//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Covers the line below which reading a file whole cost nothing a digest could have saved.
@Suite(.temporaryDirectories)
struct DigestFloorTests {
    private static func write(_ source: String, trailingNewline: Bool = true) throws -> String {
        let url = try TemporaryDirectory.make("floor")
            .appendingPathComponent("floor.swift")
        try (source + (trailingNewline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// `codeLines` lines of code under `proseLines` of doc comment — the two axes the shared predicate reads.
    private static func file(codeLines: Int, proseLines: Int = 0, trailingNewline: Bool = true) throws -> String {
        let prose = (0 ..< proseLines).map { "/// Paragraph \($0) of the reasoning." }
        let code = (0 ..< codeLines).map { "let value\($0) = \($0)" }
        return try write((prose + code).joined(separator: "\n"), trailingNewline: trailingNewline)
    }

    @Test
    func aSmallFileIsOneADigestWouldHaveServedAsSource() throws {
        #expect(try DigestFloor.wouldServeSource(Self.file(codeLines: 12)))
    }

    @Test
    func aLargeFileIsNot() throws {
        #expect(try !DigestFloor.wouldServeSource(Self.file(codeLines: 300)))
    }

    /// The floor asks `SourcePassthrough`'s question, not a similar-looking one of its own.
    ///
    /// The hazard: sharing the crossover constant while restating the decision around it. A 55-line file standing over 34 lines of code keeps its digest in `decide` — that is what the code ceiling is for — and a line-count-only floor would excuse a whole-file read of it anyway, flattering the share by exactly the lookups the ceiling makes worth counting.
    @Test
    func aFileUnderTheCrossoverStandingOverRealCodeIsCountedAsAMiss() throws {
        let path = try Self.file(codeLines: 34, proseLines: 21)

        #expect(!DigestFloor.wouldServeSource(path))
        // Under the crossover on lines alone, which is the reading that would excuse it.
        #expect(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count <= DigestFloor.lines)
    }

    /// The boundary is inclusive on both axes, and a trailing newline ends the last line rather than starting another — an off-by-one here silently moves every session's share.
    @Test
    func bothBoundariesAreInclusiveAndATrailingNewlineIsNotALine() throws {
        let ceiling = SourcePassthrough.degenerateCodeCeiling
        #expect(try DigestFloor.wouldServeSource(Self.file(codeLines: ceiling)))
        #expect(try !DigestFloor.wouldServeSource(Self.file(codeLines: ceiling + 1)))

        let prose = DigestFloor.lines - ceiling
        #expect(try DigestFloor.wouldServeSource(Self.file(codeLines: ceiling, proseLines: prose)))
        #expect(try !DigestFloor.wouldServeSource(Self.file(codeLines: ceiling, proseLines: prose + 1)))
        #expect(try DigestFloor.wouldServeSource(Self.file(codeLines: ceiling, proseLines: prose, trailingNewline: false)))
    }

    /// A block comment closing part-way along its line does not swallow the rest of the file here either — the floor reads the same scanner the decision does.
    @Test
    func aBlockCommentClosingMidLineDoesNotExcuseTheFileBelowIt() throws {
        let code = (0 ..< 24).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let path = try Self.write("/* legacy spelling, kept */ let opened = 0\n" + code)

        #expect(!DigestFloor.wouldServeSource(path))
    }

    /// A Markdown document is weighed in its own units — non-blank lines — not by the scanner written for Swift.
    ///
    /// The hazard is not theoretical in a repo whose docs quote code: a fenced block opening `/*` leaves the comment scan inside a comment for the rest of the document, so judged as source this 40-line doc looks like two lines of code and every read of it would be excused as free. `digest` itself weighs a `.md` against its non-blank lines (`SourcePassthrough.Subject.markdown`), and the floor asks that same question.
    @Test
    func aMarkdownDocumentIsJudgedByItsNonBlankLinesRatherThanByTheCommentScan() throws {
        let document = (["# Title", "", "```swift", "/* the legacy spelling, quoted mid-snippet"]
            + (0 ..< 36).map { "Paragraph \($0) of the reasoning, which is text and not a comment." })
            .joined(separator: "\n")
        let url = try TemporaryDirectory.make("floor").appendingPathComponent("Design.md")
        try (document + "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(!DigestFloor.wouldServeContent(url.path))
        // The same bytes read as Swift: the block comment swallows the document and the read is excused.
        #expect(DigestFloor.wouldServeSource(url.path))
    }

    /// The memo stands in for `wouldServeContent`, not `wouldServeSource` — a memoised caller judging a `.md` path by the Swift floor would get the wrong answer on exactly the document the two disagree about above.
    @Test
    func theMemoAgreesWithWouldServeContentNotWouldServeSource() throws {
        let document = (["# Title", "", "```swift", "/* the legacy spelling, quoted mid-snippet"]
            + (0 ..< 36).map { "Paragraph \($0) of the reasoning, which is text and not a comment." })
            .joined(separator: "\n")
        let url = try TemporaryDirectory.make("floor").appendingPathComponent("Design.md")
        try (document + "\n").write(to: url, atomically: true, encoding: .utf8)

        let memoised = DigestFloor.memoised()

        #expect(memoised(url.path) == DigestFloor.wouldServeContent(url.path))
        #expect(!memoised(url.path))
        #expect(memoised(url.path) != DigestFloor.wouldServeSource(url.path))
    }

    /// A short note is below the floor either way — an outline of a page and a half is the case `digest` answers with the document itself.
    @Test
    func aShortDocumentIsOneAnOutlineWouldHaveServedWhole() throws {
        let url = try TemporaryDirectory.make("floor").appendingPathComponent("Notes.md")
        try "# Notes\n\nTwo lines, and nothing to locate by.\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(DigestFloor.wouldServeContent(url.path))
    }

    /// A file that cannot be read is not excused.
    ///
    /// On another machine, or after a delete, whether the read cost anything is unknown, and the conservative reading is that it did — the same direction every other judgement here rounds.
    @Test
    func anUnreadableFileIsCountedAsAMissRatherThanExcused() {
        #expect(!DigestFloor.wouldServeSource("/nonexistent/Gone.swift"))
    }
}
