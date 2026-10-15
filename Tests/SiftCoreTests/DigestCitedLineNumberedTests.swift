//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the answer to one cited line inside a long function: the window's lines carry their numbers as Read lays them out (six columns, right-aligned, a tab, the line), the cited line is marked `>` in place of its first padding space, and nothing repeats what the header says — no declaration, no skip marker, no `read it by range` footer.
@Suite(.temporaryDirectories)
struct DigestCitedLineNumberedTests {
    /// A 41-line top-level function (`:1-41`, the file's last line its closing brace), with body line `L` reading `step-(L - 2)`.
    private static var source: String {
        let body = (0 ..< 39).map { "    _ = \"step-\($0)\"" }.joined(separator: "\n")
        return "func tall() {\n\(body)\n}\n"
    }

    private static func render(_ line: Int) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Gizmo/Tall.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: "Sources/Gizmo/Tall.swift:\(line)", options: DigestOptions())
    }

    /// The window lines of an answer: everything after the header's blank line.
    private static func windowLines(_ output: String) -> [String] {
        Array(output.components(separatedBy: "\n").drop { !$0.isEmpty }.dropFirst())
    }

    @Test
    func theNumbersMatchTheSourceLinesAndTheCitedLineIsMarked() throws {
        let output = try Self.render(20)

        #expect(Self.windowLines(output) == [
            "    17\t    _ = \"step-15\"",
            "    18\t    _ = \"step-16\"",
            "    19\t    _ = \"step-17\"",
            ">   20\t    _ = \"step-18\"",
            "    21\t    _ = \"step-19\"",
            "    22\t    _ = \"step-20\"",
            "    23\t    _ = \"step-21\"",
        ])
        #expect(output.contains(" lines 17-23 (line 20 with up to 3 lines either side), in Gizmo.tall() — func — :1-41 (41 lines;"))
    }

    @Test
    func theWindowCarriesNoDeclarationSkipMarkerOrFooter() throws {
        let output = try Self.render(20)

        #expect(!output.contains("func tall() {\n"))
        #expect(!output.contains("skipped"))
        #expect(!output.contains("read it by range"))
        #expect(!output.contains("lines 1-41;"))
        #expect(output.components(separatedBy: "\n").filter { $0.contains("\t") }.count == 7)
    }

    @Test
    func aLineInTheFirstThreeLinesOfTheMemberStartsTheWindowAtTheMembersFirstLine() throws {
        let output = try Self.render(3)

        #expect(Self.windowLines(output) == [
            "     1\tfunc tall() {",
            "     2\t    _ = \"step-0\"",
            ">    3\t    _ = \"step-1\"",
            "     4\t    _ = \"step-2\"",
            "     5\t    _ = \"step-3\"",
            "     6\t    _ = \"step-4\"",
        ])
        #expect(!output.contains("read it by range"))
    }

    @Test
    func theLastLineOfTheFileEndsTheWindowThere() throws {
        let output = try Self.render(41)

        #expect(Self.windowLines(output) == [
            "    38\t    _ = \"step-36\"",
            "    39\t    _ = \"step-37\"",
            "    40\t    _ = \"step-38\"",
            ">   41\t}",
        ])
        #expect(!output.contains("read it by range"))
    }
}
