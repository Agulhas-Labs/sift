//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The scan behind `where --refs`'s `not code` section: each line that writes the name outside code counted once under the first of DocC link, doc comment, comment, string literal it holds, Markdown lines apart, and file names matched at camel-case word boundaries.
@Suite(.temporaryDirectories)
struct NonCodeMentionsTests {
    private static func scan(_ name: String, swift: [String: String], markdown: [String: String] = [:]) throws -> NonCodeMentions {
        let root = try TemporaryDirectory.make("noncode")
        for (path, text) in swift.merging(markdown, uniquingKeysWith: { first, _ in first }) {
            try TestSources.write(text, to: path, in: root)
        }
        return NonCodeMentions.scan(name: name, swiftFiles: swift.keys.sorted(), markdownFiles: markdown.keys.sorted(), under: root)
    }

    /// Every kind of place in one Swift file, each line under the first kind of the priority order it holds, a whole word only, and the line that also writes the name in code counted as such.
    @Test
    func aSwiftFileCountsEachLineOnceUnderTheFirstKindItHolds() throws {
        let source = """
        /// A ``Gizmo`` holds parts, and so does every Gizmo.
        /// The Gizmo is built here.
        struct Gizmo {
            // Gizmo, in a comment.
            let label = "Gizmo"
            let other = Gizmo() // a Gizmo
            /* Gizmo */
            /** Gizmo */
            let tail = "Gizmo" // Gizmo
            let core = GizmoCore()
            /**/ let after = Gizmo()
        }
        """
        let found = try Self.scan("Gizmo", swift: ["Sources/Gizmo.swift": source])
        let file = try #require(found.files.first)

        #expect(file.lines(of: .docLink) == [1])
        #expect(file.lines(of: .doc) == [2, 8])
        #expect(file.lines(of: .comment) == [4, 6, 7, 9])
        #expect(file.lines(of: .string) == [5])
        #expect(file.codeLines == 1)
        #expect(found.codeLines == 1)
        #expect(found.count(of: .comment) == 4)
    }

    /// A DocC link is a hit between a pair of runs of exactly two backticks: a fence of three is no pair, a single backtick is a doc hit, and an unclosed pair is no link.
    @Test
    func onlyRunsOfExactlyTwoBackticksMakeADocCLink() throws {
        let source = """
        /// ```Gizmo```
        /// `Gizmo`
        /// ``Gizmo/build()``
        /// ``Gizmo
        /// ``Beta`` then Gizmo then ``Alpha``
        """
        let file = try #require(Self.scan("Gizmo", swift: ["Sources/Notes.swift": source]).files.first)

        #expect(file.lines(of: .docLink) == [3])
        #expect(file.lines(of: .doc) == [1, 2, 4, 5])
    }

    /// A Markdown file's double-backtick hit is a DocC link, as an article's is, and any other whole-word hit is a Markdown line.
    @Test
    func aMarkdownFileCountsItsDocCLinksApart() throws {
        let found = try Self.scan("Gizmo", swift: [:], markdown: ["Docs/Guide.md": "# Gizmo\n\nSee ``Gizmo`` and `Gizmo`.\nNo GizmoCore here.\n"])
        let file = try #require(found.files.first)

        #expect(file.isMarkdown)
        #expect(file.lines(of: .docLink) == [3])
        #expect(file.lines(of: .markdown) == [1])
        #expect(found.markdownFilesRead == 1)
    }

    /// A name that starts lowercase is an ordinary word too: doc, comment and Markdown hits count only inside backticks, a string literal counts as written, and no file name is matched.
    @Test
    func aLowercaseNameCountsInProseOnlyInsideBackticks() throws {
        let source = """
        /// Call `parse` first.
        /// We parse it here.
        // parse, in a comment.
        // ``parse(_:)`` links it.
        let label = "parse"
        let note = "we parse it"
        func parse() {}
        """
        let found = try Self.scan(
            "parse",
            swift: ["Sources/parse.swift": source],
            markdown: ["README.md": "We parse files.\nUse `parse` to read.\n"]
        )
        let swift = try #require(found.files.last)
        #expect(swift.lines(of: .doc) == [1])
        #expect(swift.lines(of: .comment) == [4])
        #expect(swift.lines(of: .string) == [5])
        let markdown = try #require(found.files.first)
        #expect(markdown.lines(of: .markdown) == [2])
        #expect(found.fileNames.isEmpty)
    }

    /// For a lowercase name a backtick span, in a doc comment, a comment or a string alike, counts only when it is the name, a call of it, or a member of something: a span holding a longer command does not.
    @Test
    func aLowercaseNameCountsOnlyInBacktickSpansThatReadAsReferences() throws {
        let source = [
            "/// Run `sift parse <target>` first.",
            "/// Call `Parser.parse` here.",
            "/// Call `value.parse()` here.",
            "/// See `parse(_:)` for it.",
            "/// Read ``Parser/parse(_:)`` for it.",
            "/// Run ``sift parse`` first.",
            "let first = \"use `parse` here\"",
            "let second = \"run `sift parse <target>`\"",
            "let third = \"parse\"",
            "let fourth = \"\"\"\n  parse\n  \"\"\"",
            "let fifth = \"x \\(\"parse\") y\"",
            "let sixth = \"we parse it\"",
        ].joined(separator: "\n")
        let found = try Self.scan("parse", swift: ["Sources/Use.swift": source])
        let file = try #require(found.files.first)

        #expect(file.lines(of: .docLink) == [5])
        #expect(file.lines(of: .doc) == [2, 3, 4])
        #expect(file.lines(of: .string) == [7, 9, 11, 13])
    }

    /// For a lowercase name a Markdown fenced block counts a hit only where it reads as code, after a `.` or before a `(`; the prose around the fence still wants backticks.
    @Test
    func aLowercaseNameInAMarkdownFenceCountsOnlyWhereItReadsAsCode() throws {
        let markdown = [
            "We parse files.",
            "```swift",
            "let value = parse",
            "let other = reader.parse",
            "parse(input)",
            "```",
            "We parse after the fence.",
            "~~~",
            "run parse today",
            "~~~",
            "Use `parse` last.",
        ].joined(separator: "\n")
        let found = try Self.scan("parse", swift: [:], markdown: ["Docs/Guide.md": markdown])
        let file = try #require(found.files.first)

        #expect(file.lines(of: .markdown) == [4, 5, 11])
    }

    /// An exact stem matches, the stem before a `+` included; the name as whole camel-case words in another stem is a lead; a stem that runs the name into a lowercase word is no match.
    @Test
    func aFileNameMatchesByItsExactStemAndLeadsByCamelCaseWords() {
        #expect(NonCodeMentions.fileName(of: "Sources/Gizmo.swift", matching: "Gizmo") == NonCodeMentions.FileName(path: "Sources/Gizmo.swift", isLead: false))
        #expect(NonCodeMentions.fileName(of: "Sources/Gizmo+Codable.swift", matching: "Gizmo") == NonCodeMentions.FileName(path: "Sources/Gizmo+Codable.swift", isLead: false))
        #expect(NonCodeMentions.fileName(of: "Tests/GizmoTests.swift", matching: "Gizmo") == NonCodeMentions.FileName(path: "Tests/GizmoTests.swift", isLead: true))
        #expect(NonCodeMentions.fileName(of: "Sources/GizmoCore.swift", matching: "Gizmo") == NonCodeMentions.FileName(path: "Sources/GizmoCore.swift", isLead: true))
        #expect(NonCodeMentions.fileName(of: "Sources/Gizmocore.swift", matching: "Gizmo") == nil)
        #expect(NonCodeMentions.fileName(of: "Sources/Gizmo.swift", matching: "Giz") == nil)
    }

    /// The Markdown files read are the ones the Swift files' rules keep: an excluded directory, a configured exclusion and a symbolic link are left out, from a listing and from the walk alike.
    @Test
    func theMarkdownFilesReadFollowTheSwiftFilesRules() throws {
        let root = try TemporaryDirectory.make("markdown")
        for path in ["README.md", "Docs/Guide.md", ".build/Notes.md", "Vendor/Skip.md", "Docs/Notes.txt"] {
            try TestSources.write("Gizmo\n", to: path, in: root)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Docs/Link.md"), withDestinationURL: root.appendingPathComponent("README.md"))
        var config = SiftConfig()
        config.exclude = ["Vendor/"]
        let walked = FileEnumerator(repoRoot: root, config: config)
        #expect(walked.markdownFiles() == ["Docs/Guide.md", "README.md"])
        var listed = walked
        listed.markdownListing = { ["README.md", ".build/Notes.md", "Vendor/Skip.md", "Docs/Link.md"] }
        #expect(listed.markdownFiles() == ["README.md"])
    }

    /// A file holding the name only in code is read and counted as read, but lists nothing.
    @Test
    func codeAloneListsNothing() throws {
        let found = try Self.scan("Gizmo", swift: ["Sources/Use.swift": "let gizmo = Gizmo()\n"])

        #expect(found.files.isEmpty)
        #expect(found.isEmpty)
        #expect(found.swiftFilesRead == 1)
    }
}
