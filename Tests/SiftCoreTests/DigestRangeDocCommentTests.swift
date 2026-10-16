//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers a cited line range that reaches doc comments: two or more declarations within the source floor come as the lines themselves under one header, and a declaration served as a block starts at the first of its doc-comment lines the range covers.
@Suite(.temporaryDirectories)
struct DigestRangeDocCommentTests {
    private static var path: String {
        "Sources/Gizmo/Panel.swift"
    }

    /// The fixture, one line per element: `Panel` is `:1-13` (six one-line properties, five led by a doc line), two functions sit at `:15-19`, `Tall` is `:22-103` (forty properties, each led by a doc line), and `run()` is `:106-109` with its doc line above.
    private static var lines: [String] {
        let panel = [
            "struct Panel {",
            "    var title = \"\"",
            "    /// The subtitle shown beneath.",
            "    var subtitle = \"\"",
            "    /// The caption shown beside.",
            "    var caption = \"\"",
            "    /// The footer shown below.",
            "    var footer = \"\"",
            "    /// The margin around.",
            "    var margin = 0",
            "    /// The border around.",
            "    var border = 0",
            "}",
            "",
            "/// Opens the panel.",
            "func open() {}",
            "",
            "/// Closes the panel.",
            "func close() {}",
            "",
            "/// A tall panel.",
            "struct Tall {",
        ]
        let tall = (0 ..< 40).flatMap { ["    /// Value \($0).", "    var v\($0) = 0"] }
        let rest = [
            "}",
            "",
            "/// Runs first.",
            "func run() {",
            "    let alpha = 1",
            "    let beta = 2",
            "}",
            "var after = 0",
            "",
        ]
        return panel + tall + rest
    }

    private static func renderer() throws -> DigestRenderer {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(lines.joined(separator: "\n"), path: path, in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    /// The fixture's lines `range`, as written.
    private static func written(_ range: ClosedRange<Int>) -> String {
        lines[(range.lowerBound - 1) ..< range.upperBound].joined(separator: "\n")
    }

    @Test
    func sixPropertiesWithTheirDocLinesComeAsTheLinesUnderOneHeader() throws {
        let output = try Self.renderer().render(target: "\(Self.path):2-12", options: DigestOptions())

        #expect(output == "\(Self.path) lines 2-12, in Gizmo.Panel — struct — :1-13 (6 declarations)\n\n" + Self.written(2 ... 12))
        #expect(output.components(separatedBy: "///").count == 6)
        #expect(!output.contains("— var —"))
    }

    @Test
    func twoTopLevelFunctionsComeAsTheLinesUnderAHeaderNamingNoType() throws {
        let output = try Self.renderer().render(target: "\(Self.path):15-19", options: DigestOptions())

        #expect(output == "\(Self.path) lines 15-19 (2 declarations)\n\n" + Self.written(15 ... 19))
    }

    @Test
    func aDocLineAndItsDeclarationComeAsOneBlockHoldingBoth() throws {
        let output = try Self.renderer().render(target: "\(Self.path):18-19", options: DigestOptions())

        #expect(output == "Gizmo.close() — func — \(Self.path):19\n\n" + Self.written(18 ... 19))
    }

    @Test
    func aRangePastTheFloorIsABlockPerDeclarationEachOpeningAtItsFirstDocLineInside() throws {
        let output = try Self.renderer().render(target: "\(Self.path):23-85", options: DigestOptions())

        #expect(output.components(separatedBy: " — var — ").count == 33)
        #expect(output.contains("    /// Value 0.\n    var v0 = 0"))
        #expect(output.contains("    /// Value 30.\n    var v30 = 0"))
        // The last property is reached only by its doc line, and is served from that line.
        #expect(output.hasSuffix("\n    /// Value 31.\n    var v31 = 0"))
        #expect(!output.contains("lines 23-"))
    }

    @Test
    func aFunctionTheRangeReachesInsideItsBodyIsServedFromItsDeclarationLine() throws {
        let output = try Self.renderer().render(target: "\(Self.path):108-110", options: DigestOptions())

        #expect(output == "\(Self.path) lines 106-110 (2 declarations)\n\n" + Self.written(106 ... 110))
        #expect(!output.contains("Runs first."))
    }

    @Test
    func anOffsetAcrossSeveralDeclarationsIsStillRefused() throws {
        let renderer = try Self.renderer()

        #expect(throws: EngineError.self) {
            try renderer.render(target: "\(Self.path):15-19", options: DigestOptions(offset: 1))
        }
    }
}
