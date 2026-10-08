//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers a single line asked for inside a function longer than `RangeInsideMemberAnswer.singleLineMemberCeiling`: the declaration, a window around the line and the range to read, where a range or a member named by type is still served whole.
@Suite(.temporaryDirectories)
struct DigestSingleLineWindowTests {
    /// `tall()` is 43 lines (`:2-44`), `edge()` one past the ceiling (`:46-71`, 26 lines), `flat()` on it (`:73-97`, 25 lines) and `wide(first:second:)` declared over four lines (`:99-133`); body line `L` of a member reads `<name>-(L - first body line)`.
    private static func ledger() throws -> DigestRenderer {
        let source = "struct Ledger {\n\(member("tall", lines: 41))\n\n\(member("edge", lines: 24))\n\n\(member("flat", lines: 23))\n\n\(wide)\n}\n"
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Gizmo/Ledger.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    private static var wide: String {
        let body = (0 ..< 30).map { "        _ = \"wide-\($0)\"" }.joined(separator: "\n")
        return "    private static func wide(\n        first: Int,\n        second: String\n    ) {\n\(body)\n    }"
    }

    private static func member(_ name: String, lines: Int) -> String {
        let body = (0 ..< lines).map { "        _ = \"\(name)-\($0)\"" }.joined(separator: "\n")
        return "    private static func \(name)() {\n\(body)\n    }"
    }

    /// Source lines `lines` of `tall()`'s body, as the file carries them.
    private static func tallLines(_ lines: ClosedRange<Int>) -> String {
        lines.map { "        _ = \"tall-\($0 - 3)\"" }.joined(separator: "\n")
    }

    @Test
    func aLineInTheMiddleOfALongFunctionComesBeneathItsDeclarationWithTheRangeToRead() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:23", options: DigestOptions())

        #expect(output == """
        Sources/Gizmo/Ledger.swift lines 20-26 (line 23 with up to 3 lines either side), in Gizmo.Ledger.tall() — func — :2-44 (43 lines; digest Gizmo.Ledger.tall() for all of it)

            private static func tall()
        (…17 lines skipped)
        \(Self.tallLines(20 ... 26))
        lines 2-44; read it by range
        """)
        #expect(output.utf8.count < 500)
    }

    @Test
    func aLineBesideTheDeclarationShowsItOnceInTheWindow() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:3", options: DigestOptions())

        #expect(output.hasSuffix("\n\n    private static func tall() {\n" + Self.tallLines(3 ... 6) + "\nlines 2-44; read it by range"))
        #expect(output.components(separatedBy: "private static func tall()").count == 2)
    }

    @Test
    func aLineInAFunctionOnePastTheCeilingIsWindowedAndOneOnItIsServedWhole() throws {
        let renderer = try Self.ledger()
        let past = try renderer.render(target: "Sources/Gizmo/Ledger.swift:58", options: DigestOptions())
        let atCeiling = try renderer.render(target: "Sources/Gizmo/Ledger.swift:85", options: DigestOptions())

        #expect(past.hasPrefix("Sources/Gizmo/Ledger.swift lines 55-61 (line 58 with up to 3 lines either side), in Gizmo.Ledger.edge() — func — :46-71 (26 lines;"))
        #expect(!past.contains("\"edge-0\""))
        #expect(atCeiling.hasPrefix("Gizmo.Ledger.flat() — func — Sources/Gizmo/Ledger.swift:73-97\n\n    private static func flat() {\n"))
        #expect(atCeiling.contains("\"flat-0\""))
        #expect(atCeiling.hasSuffix("\"flat-22\"\n    }"))
    }

    @Test
    func aRangeOrAMemberNamedByTypeInsideALongFunctionIsServedWhole() throws {
        let renderer = try Self.ledger()
        let range = try renderer.render(target: "Sources/Gizmo/Ledger.swift:22-24", options: DigestOptions())
        let named = try renderer.render(target: "Ledger.tall", options: DigestOptions())

        for output in [range, named] {
            #expect(output.hasPrefix("Gizmo.Ledger.tall() — func — Sources/Gizmo/Ledger.swift:2-44\n\n    private static func tall() {\n"))
            #expect(output.hasSuffix("\"tall-40\"\n    }"))
            #expect(!output.contains("read it by range"))
        }
    }

    @Test
    func aDeclarationWrittenOverSeveralLinesIsShownAsItsDigestLineShowsIt() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:120", options: DigestOptions())

        #expect(output.contains("\n\n    private static func wide(first: Int, second: String)\n(…14 lines skipped)\n        _ = \"wide-14\"\n"))
        #expect(output.hasSuffix("_ = \"wide-20\"\nlines 99-133; read it by range"))
    }
}
