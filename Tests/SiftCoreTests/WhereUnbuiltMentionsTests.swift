//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A semantic `where` whose count is a lower bound because test files lie outside the build lists the lines in those files that write the name, so a rename trusting the answer does not miss them.
@Suite(.serialized, .temporaryDirectories)
struct WhereUnbuiltMentionsTests {
    /// Built with its tests, a package with a stray test file outside any built target: the line writing `Box` in code is listed under the type and under its `--refs` sweep, the comment naming it is not, and a property the stray file never names gets no such line.
    @Test
    func aStrayTestFileListsTheCodeLinesThatWriteTheName() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public var idle = 0\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("func make() -> Box {\n    Box()\n}\n", to: "Sources/Lib/Maker.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write(
            "@testable import Lib\nimport Testing\n\n// Box is named here in a comment only.\n@Test func strays() {\n    #expect(Box().walk == 1)\n}\n",
            to: "Fixtures/BetaTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let type = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh())
        let sweep = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
        let property = try await engine.lookup(symbol: "Box.idle", freshness: engine.ensureFresh())

        for answer in [type, sweep] {
            #expect(answer.contains("a lower bound (1 test file outside any built target)"), "\(answer)")
            #expect(answer.split(separator: "\n").contains("not in the build, mention the name: Fixtures/BetaTests.swift:6"), "\(answer)")
        }

        #expect(property.contains("not counting 1 test file outside any built target"), "\(property)")
        #expect(!property.contains("not in the build, mention the name"), "\(property)")
    }

    /// Built without its tests, the same package lists nothing: every test file lacks a unit, so none is read, and the lower bound's build advice is the whole remedy.
    @Test
    func noTestBuildReadsNoFileAndAddsNoLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("func make() -> Box {\n    Box()\n}\n", to: "Sources/Lib/Maker.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let sweep = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(sweep.contains("build with `sift run -- swift build --build-tests`"), "\(sweep)")
        #expect(!sweep.contains("not in the build, mention the name"), "\(sweep)")
    }

    /// A lex, no parse: the name as a whole word counts in code, as `$name`, backticked, and in a string literal, never in a comment line, a block comment's lines or the part of a line after `//`, nor inside a longer word; a file with a byte that is not UTF-8 is still read.
    @Test
    func theScanCountsWholeWordsInCodeAndStringsNotComments() throws {
        let root = try TestSources.makeTempDirectory()
        let lines = [
            "@testable import Lib",
            "// walk in a comment",
            "/// walk in a doc comment",
            "/* walk opens a block",
            " * walk continues it */",
            "let projected = $walk",
            "let escaped = `walk`",
            "let quoted = \"walk\"",
            "let other = walker + walks // walk after code",
            "let trailing = 1 // walk",
            "box.walk = 2",
        ]
        try TestSources.write(lines.joined(separator: "\n") + "\n", to: "Fixtures/GizmoTests.swift", in: root)
        try (Data([0xFF, 0x0A]) + Data("let stray = walk\n".utf8)).write(to: root.appendingPathComponent("Fixtures/GadgetTests.swift"))
        try TestSources.write("let idle = 0\n", to: "Fixtures/BetaTests.swift", in: root)

        let found = WhereUnbuiltMentions.mentions(of: ["walk"], in: ["Fixtures/GizmoTests.swift", "Fixtures/GadgetTests.swift", "Fixtures/BetaTests.swift"], under: root.path)

        #expect(found == [
            NameMention(path: "Fixtures/GadgetTests.swift", line: 2),
            NameMention(path: "Fixtures/GizmoTests.swift", line: 6),
            NameMention(path: "Fixtures/GizmoTests.swift", line: 7),
            NameMention(path: "Fixtures/GizmoTests.swift", line: 8),
            NameMention(path: "Fixtures/GizmoTests.swift", line: 11),
        ])
    }

    /// The lexer tells a comment from code a line scan misread: `//` inside a string, code after a closed `/* */`, and a line opening with the `*` operator all count, as do raw, multi-line and interpolated strings; a block comment spanning lines, a nested one, and the text after `//` do not; a letter that is not ASCII against the name makes a longer word, punctuation that is not ASCII does not.
    @Test
    func theLexerKeepsCodeThatLooksLikeACommentAndDropsCommentsThatSpanLines() throws {
        let root = try TestSources.makeTempDirectory()
        let lines = [
            "let a = \"http://x\" + w.walk",
            "/* c */ let c = w.walk",
            "let total = 1",
            "    * w.walk.count",
            "/* opens a block",
            "   walk inside it",
            "*/",
            "let after = 2 // walk only after the code",
            "/* outer /* inner */ walk still in the outer */",
            "let raw = #\"say \"walk\" \\(x)\"#",
            "let interpolated = \"\\(f(\"x\")) // walk\"",
            "let text = \"\"\"",
            "    // walk in a multi-line string",
            "    \"\"\"",
            "let last = 3",
            "let accented = éwalk + walkø + \"…walk…\"",
        ]
        try TestSources.write(lines.joined(separator: "\n") + "\n", to: "Fixtures/GizmoTests.swift", in: root)

        let found = WhereUnbuiltMentions.mentions(of: ["walk"], in: ["Fixtures/GizmoTests.swift"], under: root.path)

        #expect(found.map(\.line) == [1, 2, 4, 10, 11, 13, 16])
    }

    /// Past the scan cap, the files in path order beyond it that write the name are not lexed and are counted as not scanned, while a file without the name costs nothing against the cap, so a bounded scan never reads as a complete one.
    @Test
    func filesPastTheScanCapAreCountedAsNotScanned() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write("let a = w.walk\n", to: "Fixtures/AlphaTests.swift", in: root)
        try TestSources.write("let b = 0\n", to: "Fixtures/BetaTests.swift", in: root)
        try TestSources.write("let c = w.walk\n", to: "Fixtures/GadgetTests.swift", in: root)
        let paths = ["Fixtures/GadgetTests.swift", "Fixtures/BetaTests.swift", "Fixtures/AlphaTests.swift"]

        let capped = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path, scanCap: 1)
        let missed = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path, scanCap: 0)
        let whole = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path)

        #expect(capped == "not in the build, mention the name: Fixtures/AlphaTests.swift:1 · 1 outside file not scanned")
        #expect(missed == "not in the build, mention the name: none in the files scanned · 2 outside files not scanned")
        #expect(whole == "not in the build, mention the name: Fixtures/AlphaTests.swift:1 · Fixtures/GadgetTests.swift:1")
    }

    /// The first ten files are listed with their lines, each file's lines capped with a count of the rest, and the files past the cap are counted with their lines, so no mentioning line leaves the answer.
    @Test
    func theListingCapsFilesAndLinesAndCountsWhatItCuts() throws {
        let many = (1 ... 12).map { NameMention(path: String(format: "Fixtures/Gizmo%02d.swift", $0), line: 7) }
            + (1 ... 32).map { NameMention(path: "Fixtures/Gizmo01.swift", line: 100 + $0) }
            + [NameMention(path: "Fixtures/Gizmo12.swift", line: 9)]
        let sorted = many.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        let line = try #require(WhereUnbuiltMentions.line(listing: sorted))

        let entries = line.dropFirst("not in the build, mention the name: ".count).components(separatedBy: " · ")
        #expect(entries.count == 11, "\(line)")
        let firstLines = [7] + Array(101 ... 129)
        let firstEntry = "Fixtures/Gizmo01.swift:" + firstLines.map(String.init).joined(separator: ",") + ", +3 more"
        #expect(entries.first == firstEntry, "\(line)")
        #expect(entries.contains("Fixtures/Gizmo10.swift:7"), "\(line)")
        #expect(entries.last == "… 2 more files, 3 lines", "\(line)")
        #expect(WhereUnbuiltMentions.line(listing: []) == nil)
    }
}
