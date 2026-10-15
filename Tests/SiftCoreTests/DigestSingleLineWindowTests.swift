//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers a single line asked for inside a function longer than `RangeInsideMemberAnswer.singleLineMemberCeiling`: a window of numbered lines around it under a header naming the function and its range, where a range or a member named by type is still served whole.
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

    /// `lines` of the file as a cited line's answer numbers them.
    ///
    /// The number is right-aligned to six columns, then a tab, then the line; `>` takes the first padding space of `cited`. `text` is the source line at a number.
    private static func numbered(_ lines: ClosedRange<Int>, cited: Int, _ text: (Int) -> String) -> String {
        lines.map { (($0 == cited ? ">" : " ") + String(repeating: " ", count: 5 - String($0).count) + String($0)) + "\t" + text($0) }.joined(separator: "\n")
    }

    private static func tallText(_ line: Int) -> String {
        line == 2 ? "    private static func tall() {" : "        _ = \"tall-\(line - 3)\""
    }

    @Test
    func aLineInTheMiddleOfALongFunctionComesAsNumberedLinesUnderTheHeaderAlone() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:23", options: DigestOptions())

        #expect(output == """
        Sources/Gizmo/Ledger.swift lines 20-26 (line 23 with up to 3 lines either side), in Gizmo.Ledger.tall() — func — :2-44 (43 lines; digest Gizmo.Ledger.tall() for all of it)

        \(Self.numbered(20 ... 26, cited: 23, Self.tallText))
        """)
        #expect(output.utf8.count < 500)
    }

    @Test
    func aLineBesideTheDeclarationNumbersTheDeclarationLineAsOneOfTheWindow() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:3", options: DigestOptions())

        #expect(output.hasSuffix("\n\n" + Self.numbered(2 ... 6, cited: 3, Self.tallText)))
        #expect(output.components(separatedBy: "private static func tall()").count == 2)
        #expect(!output.contains("read it by range"))
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
    func aLineInTheBodyOfAFunctionWithAMultiLineDeclarationCarriesNoDeclaration() throws {
        let output = try Self.ledger().render(target: "Sources/Gizmo/Ledger.swift:120", options: DigestOptions())

        #expect(output.hasSuffix("\n\n" + Self.numbered(117 ... 123, cited: 120) { "        _ = \"wide-\($0 - 103)\"" }))
        #expect(!output.contains("second: String"))
        #expect(!output.contains("skipped"))
        #expect(!output.contains("read it by range"))
    }
}
