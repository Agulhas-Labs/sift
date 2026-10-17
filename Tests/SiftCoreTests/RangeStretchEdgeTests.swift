//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the edges of a cited line range of several declarations served as the lines themselves: the end of the file and the type the header names.
@Suite(.temporaryDirectories)
struct RangeStretchEdgeTests {
    private static var path: String {
        "Sources/App/Shapes.swift"
    }

    /// The fixture, thirty lines ending in a newline: `Beta` is `:20-29` holding seven properties at `:22-28`, and line 30 is a comment outside it.
    private static var lines: [String] {
        let before = (1 ... 19).map { "let top\($0) = 0" }
        let beta = ["struct Beta {", "    var one = 0"] + (2 ... 8).map { "    var v\($0) = 0" } + ["}"]
        return before + beta + ["// trailing", ""]
    }

    private static func render(_ range: String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(lines.joined(separator: "\n"), path: path, in: root)
        try store.replaceFiles([parsed]) { _ in ("App", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: "\(path):\(range)", options: DigestOptions())
    }

    @Test
    func aRangeOneLinePastTheEndOfTheFileServesNoLineThatIsNotThere() throws {
        let output = try Self.render("22-31")

        #expect(!output.contains("lines 22-31"))
    }

    @Test
    func aRangeEndingOnTheLastLineIsStillServedAsTheLines() throws {
        let output = try Self.render("22-30")

        #expect(output.hasPrefix("\(Self.path) lines 22-30"))
        #expect(output.hasSuffix("// trailing"))
    }

    @Test
    func theHeaderNamesNoTypeWhoseRangeLeavesOutALineServed() throws {
        let output = try Self.render("22-30")

        #expect(output.hasPrefix("\(Self.path) lines 22-30 ("))
        #expect(!output.contains("Beta — struct"))
    }

    @Test
    func theHeaderNamesTheTypeWhereTheLinesLieWithinIt() throws {
        let output = try Self.render("22-28")

        #expect(output.hasPrefix("\(Self.path) lines 22-28, in App.Beta — struct — :20-29"))
    }
}
