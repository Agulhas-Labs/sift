//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where --refs` is the rename sweep, so it leaves no code site to a grep and reads the Markdown of the hidden directories where agent notes live.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefsSweepCompleteTests {
    /// A built package with a type used on 45 lines of one file, past both the text cap and the per-file cap.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-sweep-complete") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public struct Gadget: Sendable {\n    public init() {}\n}\n", to: "Sources/Lib/Gadget.swift", in: root)
            try TestSources.write((1 ... 45).map { "public let piece\($0) = Gadget()" }.joined(separator: "\n") + "\n", to: "Sources/Lib/Lots.swift", in: root)
            try TestSources.commitAll(in: root, message: "refs sweep fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// With a store, a type used on 45 lines of one file lists every one of them under `--refs`, with nothing counted as hidden.
    @Test
    func aStoreSweepListsEveryLineOfAFile() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let all = (1 ... 45).map(String.init).joined(separator: ", ")

            #expect(output.contains("Sources/Lib/Lots.swift (45): \(all)"), "\(output)")
            #expect(!output.contains("more"), "\(output)")
            #expect(!output.contains("past the per-file cap"), "\(output)")
        }
    }

    /// The Markdown scan reads the hidden directories that keep notes, from the walk and from a git listing alike, and still skips `.git`, `.build`, `.swiftpm`, `.sift`, vendored directories and configured exclusions.
    @Test
    func theMarkdownScanReadsHiddenNoteDirectories() throws {
        let root = try TemporaryDirectory.make("hidden-markdown")
        let paths = [
            "README.md", ".agents/Project.md", ".github/Notes.md", ".claude/rules/Rule.md",
            ".git/Skip.md", ".build/Skip.md", ".swiftpm/Skip.md", ".sift/Skip.md", "Vendor/Skip.md", "Pods/Skip.md",
        ]
        for path in paths {
            try TestSources.write("Gizmo\n", to: path, in: root)
        }
        var config = SiftConfig()
        config.exclude = ["Vendor/"]
        let expected = [".agents/Project.md", ".claude/rules/Rule.md", ".github/Notes.md", "README.md"]
        let walked = FileEnumerator(repoRoot: root, config: config)
        #expect(walked.markdownFiles() == expected)
        var listed = walked
        listed.markdownListing = { paths }
        #expect(listed.markdownFiles() == expected)
        #expect(walked.swiftFiles().isEmpty)
    }

    /// A Markdown file naming the symbol on 35 lines, past the per-file cap, lists all 35 in the not-code section, and the file names row lists every name.
    @Test
    func theNotCodeSectionListsEveryLineAndEveryFileName() {
        let lines = (1 ... 35).map { NonCodeMentions.Line(number: $0, kind: .markdown) }
        let names = (1 ... WhereRenderer.listCap + 5).map { NonCodeMentions.FileName(path: "Sources/Gizmo\($0).swift", isLead: false) }
        let file = NonCodeMentions.File(path: ".agents/Notes.md", isMarkdown: true, lines: lines, codeLines: 0)
        let section = WhereNonCodeSection(mentions: NonCodeMentions(files: [file], fileNames: names, swiftFilesRead: 1, markdownFilesRead: 1), isAmbiguous: false)

        let rows = section.lines(offset: 0, paging: SyntacticSweepPaging(offset: 0), joinsPager: false)

        #expect(rows.contains("  .agents/Notes.md (35): " + (1 ... 35).map(String.init).joined(separator: ", ")), "\(rows)")
        #expect(rows.contains("  file names: " + names.map(\.path).joined(separator: ", ")), "\(rows)")
        #expect(!rows.joined().contains("more"), "\(rows)")
    }

    /// Twelve test files outside the build, past the ten-file cap, are all listed with every line under `--refs`; the plain answer keeps its caps.
    @Test
    func theUnbuiltMentionsListEveryFileAndLineUnderRefs() throws {
        let root = try TestSources.makeTempDirectory()
        let paths = "abcdefghijkl".map { "Fixtures/\($0)/GizmoTests.swift" }
        let body = (1 ... 35).map { _ in "let x = w.walk" }.joined(separator: "\n") + "\n"
        for path in paths {
            try TestSources.write(body, to: path, in: root)
        }
        let all = (1 ... 35).map(String.init).joined(separator: ",")

        let sweep = try #require(WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path, listsEveryLine: true))
        let plain = try #require(WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path))

        #expect(paths.allSatisfy { sweep.contains("\($0):\(all)") }, "\(sweep)")
        #expect(!sweep.contains("more"), "\(sweep)")
        #expect(!plain.contains("Fixtures/l/GizmoTests.swift:"), "\(plain)")
        #expect(plain.contains("… 2 more files, 70 lines"), "\(plain)")
        #expect(plain.contains("+5 more"), "\(plain)")
    }

    /// Under `--refs` a hit scan bound still says how many files it did not read.
    @Test
    func theScanBoundStillCountsFilesNotScannedUnderRefs() throws {
        let root = try TestSources.makeTempDirectory()
        let paths = "abc".map { "Fixtures/\($0)/GizmoTests.swift" }
        for path in paths {
            try TestSources.write("let x = w.walk\n", to: path, in: root)
        }

        let line = WhereUnbuiltMentions.line(for: ["walk"], in: paths, under: root.path, scanCap: 2, listsEveryLine: true)

        #expect(line == "not in the build, mention the name: Fixtures/a/GizmoTests.swift:1 · Fixtures/b/GizmoTests.swift:1 · 1 outside file not scanned")
    }
}
