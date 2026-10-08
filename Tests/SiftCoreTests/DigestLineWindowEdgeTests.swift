//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the edges of a single line's window inside a long function (see `DigestSingleLineWindowTests` for the middle): a line in the doc comment above the declaration, a window that starts inside a declaration written over several lines, and a page offset into the window.
@Suite(.temporaryDirectories)
struct DigestLineWindowEdgeTests {
    /// `tall()` is `:8-39` under a six-line doc comment (`:2-7`) and `wide(first:second:)` `:42-76` under a one-line one, its declaration over `:42-45`; body line `L` of a member reads `<name>-(L - first body line)`.
    private static func ledger() throws -> DigestRenderer {
        let docs = ["One", "Two", "Three", "Four", "Five", "Six"].map { "    /// \($0)." }.joined(separator: "\n")
        let source = "struct Ledger {\n\(docs)\n\(member("tall", head: "private static func tall() {"))\n\n    /// Wide.\n\(member("wide", head: "private static func wide(\n        first: Int,\n        second: String\n    ) {"))\n}\n"
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
    func aLineInTheDocCommentComesWithTheDeclarationBeneathTheDocLines() throws {
        let output = try render(2)

        #expect(output.contains("""

            /// One.
            /// Two.
            /// Three.
            /// Four.
        (…2 lines skipped)
            private static func tall()
        lines 8-39; read it by range
        """))
        #expect(output.components(separatedBy: "private static func tall()").count == 2)
    }

    @Test
    func aWindowStartingInsideAMultiLineDeclarationShowsTheDeclarationOnce() throws {
        let output = try render(46)

        #expect(output.contains(" lines 42-49 (line 46 with the declaration and up to 3 lines either side), in Gizmo.Ledger.wide(first:second:)"))
        #expect(output.contains("\n\n    private static func wide(\n        first: Int,\n        second: String\n    ) {\n        _ = \"wide-0\"\n"))
        #expect(output.components(separatedBy: "second: String").count == 2)
        #expect(!output.contains("skipped"))
    }

    @Test
    func anOffsetOnAWindowBelowTheDeclarationPrintsOneSkippedMarker() throws {
        let output = try render(20, offset: 2)

        #expect(output.components(separatedBy: "lines skipped)").count == 2)
        #expect(output.contains("\n    private static func tall()\n(…10 lines skipped)\n        _ = \"tall-10\"\n"))
    }

    @Test
    func anOffsetPastTheDocLinesOfAWindowJoinsThemToTheGapBeforeTheDeclaration() throws {
        let output = try render(2, offset: 4)

        #expect(output.components(separatedBy: "lines skipped)").count == 2)
        #expect(output.contains("\n\n(…6 lines skipped)\n    private static func tall()\nlines 8-39; read it by range"))
    }

    @Test
    func anOffsetIntoAWindowWidenedToTheDeclarationStillPrintsTheWholeDeclaration() throws {
        let output = try render(47, offset: 3)

        #expect(output.contains(" lines 42-50 (line 47 with the declaration and up to 3 lines either side)"))
        #expect(output.contains("\n\n    private static func wide(first: Int, second: String)\n        _ = \"wide-0\"\n"))
        #expect(!output.contains("skipped"))
        #expect(!output.contains(") {"))
    }

    @Test
    func theGapBelowAMultiLineDeclarationCountsTheLinesPastItsLast() throws {
        let output = try render(52)

        #expect(output.contains("\n    private static func wide(first: Int, second: String)\n(…3 lines skipped)\n        _ = \"wide-3\"\n"))
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
        #expect(output.contains("\n\n    func trailing()\n(…20 lines skipped)\n        if Bool.random() {\n"))
    }

    @Test
    func aClosureInsideAStoredValueDoesNotStretchTheWindowToTheDeclaration() throws {
        let output = try almanac(51)

        #expect(output.contains("Almanac.swift lines 48-54 (line 51 with up to 3 lines either side), in Gizmo.Almanac.table"))
        #expect(output.contains("\n(…14 lines skipped)\n        { 1 },\n        {\n"))
    }

    @Test
    func aWindowReachingOnlyTheAttributesOfADeclarationShowsItsKeywordLineOnce() throws {
        let output = try almanac(60)

        #expect(output.contains("Almanac.swift lines 60-66 (line 60 with the declaration and up to 3 lines either side), in Gizmo.Almanac.marked(first:)"))
        #expect(output.contains("\n\n    /// Marked one.\n    /// Marked two.\n    @MainActor\n    @discardableResult\n    func marked(\n        first: Int\n    ) -> Int {\nlines 62-93"))
        #expect(output.components(separatedBy: "@MainActor").count == 2)
    }

    @Test
    func aDocLineWindowStoppingInsideAMultiLineDeclarationRunsToItsLastLine() throws {
        let output = try almanac(95)

        #expect(output.contains("Almanac.swift lines 95-99 (line 95 with the declaration and up to 3 lines either side), in Gizmo.Almanac.bounded(value:)"))
        #expect(output.contains("\n\n    /// Where.\n    func bounded<T>(\n        value: T\n    ) -> Int\n        where T: Equatable {\nlines 96-126"))
    }

    @Test
    func aDefaultArgumentOpeningABraceDoesNotEndTheDeclarationEarly() throws {
        let output = try almanac(133)

        #expect(output.contains("Almanac.swift lines 128-136 (line 133 with the declaration and up to 3 lines either side), in Gizmo.Almanac.defaulted(action:)"))
        #expect(output.components(separatedBy: "func defaulted").count == 2)
        #expect(!output.contains("skipped"))
    }
}
