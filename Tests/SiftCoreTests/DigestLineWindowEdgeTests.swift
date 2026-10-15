//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the edges of a single line's window inside a long function (see `DigestSingleLineWindowTests` for the middle): a line in the doc comment above the declaration, a window that starts inside a declaration written over several lines, a page offset into the window, and windows the old declaration framing had to widen.
@Suite(.temporaryDirectories)
struct DigestLineWindowEdgeTests {
    /// `tall()` is `:8-39` under a six-line doc comment (`:2-7`) and `wide(first:second:)` `:42-76` under a one-line one, its declaration over `:42-45`; body line `L` of a member reads `<name>-(L - first body line)`.
    private static var ledgerSource: String {
        let docs = ["One", "Two", "Three", "Four", "Five", "Six"].map { "    /// \($0)." }.joined(separator: "\n")
        return "struct Ledger {\n\(docs)\n\(member("tall", head: "private static func tall() {"))\n\n    /// Wide.\n\(member("wide", head: "private static func wide(\n        first: Int,\n        second: String\n    ) {"))\n}\n"
    }

    /// `lines` of `source` as a cited line's answer numbers them: the number right-aligned to six columns, a tab, the line; `>` for the first padding space of `cited`.
    private static func numbered(_ lines: ClosedRange<Int>, cited: Int, of source: String) -> String {
        let all = source.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { (($0 == cited ? ">" : " ") + String(repeating: " ", count: 5 - String($0).count) + String($0)) + "\t" + all[$0 - 1] }.joined(separator: "\n")
    }

    private static func ledger() throws -> DigestRenderer {
        let source = ledgerSource
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Gizmo/Ledger.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    private static func member(_ name: String, head: String) -> String {
        let body = (0 ..< 30).map { "        _ = \"\(name)-\($0)\"" }.joined(separator: "\n")
        return "    \(head)\n\(body)\n    }"
    }

    private func render(_ line: Int, offset: Int = 0) throws -> String {
        try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:\(line)", options: DigestOptions(offset: offset))
    }

    @Test
    func aLineInTheDocCommentComesAsTheDocLinesAloneWithoutTheDeclaration() throws {
        let output = try render(2)

        #expect(output.contains(" lines 2-5 (line 2 with up to 3 lines either side), in Gizmo.Ledger.tall()"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(2 ... 5, cited: 2, of: Self.ledgerSource)))
        #expect(!output.contains("private static func tall()\n"))
        #expect(!output.contains("read it by range"))
    }

    @Test
    func aWindowStartingInsideAMultiLineDeclarationIsTheSourceLinesAsTheyAre() throws {
        let output = try render(46)

        #expect(output.contains(" lines 43-49 (line 46 with up to 3 lines either side), in Gizmo.Ledger.wide(first:second:)"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(43 ... 49, cited: 46, of: Self.ledgerSource)))
        #expect(!output.contains("skipped"))
    }

    @Test
    func anOffsetOnAWindowNumbersTheRemainingLinesFromWhereItResumes() throws {
        let output = try render(20, offset: 2)

        #expect(output.hasSuffix("\n\n" + Self.numbered(19 ... 23, cited: 20, of: Self.ledgerSource)))
        #expect(!output.contains("skipped"))
    }

    @Test
    func anOffsetPastMostOfADocLineWindowLeavesTheLastLineNumberedByItsPlace() throws {
        let output = try render(2, offset: 3)

        #expect(output.hasSuffix("\n\n" + Self.numbered(5 ... 5, cited: 2, of: Self.ledgerSource)))
        #expect(!output.contains("skipped"))
        #expect(!output.contains("private static func tall()\n"))
    }

    @Test
    func anOffsetInsideAMultiLineDeclarationsWindowResumesAtTheLineItReaches() throws {
        let output = try render(47, offset: 3)

        #expect(output.contains(" lines 44-50 (line 47 with up to 3 lines either side)"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(47 ... 50, cited: 47, of: Self.ledgerSource)))
        #expect(!output.contains("skipped"))
    }

    @Test
    func aWindowBelowAMultiLineDeclarationNamesNoLinesItSkips() throws {
        let output = try render(52)

        #expect(output.hasSuffix("\n\n" + Self.numbered(49 ... 55, cited: 52, of: Self.ledgerSource)))
        #expect(!output.contains("skipped"))
    }

    /// The members of `almanac()` and the lines each test below asks about; body lines read `<name>-<n>`.
    private static let almanacSource = """
    struct Almanac {
        func trailing() { // why
    \(filler("trailing", 0 ..< 20))
            if Bool.random() {
                _ = "trailing-if"
            }
    \(filler("trailing", 20 ..< 25))
        }

        static let table: [() -> Int] = [
    \(Array(repeating: "        { 1 },", count: 15).joined(separator: "\n"))
            {
                2
            },
    \(Array(repeating: "        { 3 },", count: 6).joined(separator: "\n"))
        ]

        /// Marked one.
        /// Marked two.
        @MainActor
        @discardableResult
        func marked(
            first: Int
        ) -> Int {
    \(filler("marked", 0 ..< 25))
            return first
        }

        /// Where.
        func bounded<T>(
            value: T
        ) -> Int
            where T: Equatable {
    \(filler("bounded", 0 ..< 25))
            return 0
        }

        func defaulted(
            action: () -> Void = {
            }
        ) {
    \(filler("defaulted", 0 ..< 25))
        }
    }

    """

    private static func filler(_ name: String, _ numbers: Range<Int>) -> String {
        numbers.map { "        _ = \"\(name)-\($0)\"" }.joined(separator: "\n")
    }

    private func almanac(_ line: Int) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(Self.almanacSource, path: "Sources/Gizmo/Almanac.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: "Sources/Gizmo/Almanac.swift:\(line)", options: DigestOptions())
    }

    @Test
    func aBraceAfterTheDeclarationsCommentDoesNotStretchTheWindowToALaterBrace() throws {
        let output = try almanac(26)

        #expect(output.contains("Almanac.swift lines 23-29 (line 26 with up to 3 lines either side), in Gizmo.Almanac.trailing()"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(23 ... 29, cited: 26, of: Self.almanacSource)))
        #expect(!output.contains("func trailing()\n"))
    }

    @Test
    func aClosureInsideAStoredValueDoesNotStretchTheWindowToTheDeclaration() throws {
        let output = try almanac(51)

        #expect(output.contains("Almanac.swift lines 48-54 (line 51 with up to 3 lines either side), in Gizmo.Almanac.table"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(48 ... 54, cited: 51, of: Self.almanacSource)))
    }

    @Test
    func aWindowReachingOnlyTheAttributesOfADeclarationEndsWhereTheWindowDoes() throws {
        let output = try almanac(60)

        #expect(output.contains("Almanac.swift lines 60-63 (line 60 with up to 3 lines either side), in Gizmo.Almanac.marked(first:)"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(60 ... 63, cited: 60, of: Self.almanacSource)))
        #expect(output.components(separatedBy: "@MainActor").count == 2)
    }

    @Test
    func aDocLineWindowStoppingInsideAMultiLineDeclarationRunsToItsLastLine() throws {
        let output = try almanac(95)

        #expect(output.contains("Almanac.swift lines 95-98 (line 95 with up to 3 lines either side), in Gizmo.Almanac.bounded(value:)"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(95 ... 98, cited: 95, of: Self.almanacSource)))
    }

    @Test
    func aDefaultArgumentOpeningABraceDoesNotEndTheDeclarationEarly() throws {
        let output = try almanac(133)

        #expect(output.contains("Almanac.swift lines 130-136 (line 133 with up to 3 lines either side), in Gizmo.Almanac.defaulted(action:)"))
        #expect(output.hasSuffix("\n\n" + Self.numbered(130 ... 136, cited: 133, of: Self.almanacSource)))
        #expect(!output.contains("skipped"))
    }
}
