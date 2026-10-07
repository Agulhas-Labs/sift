//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The articles in `Docs/Sift.docc` tell a reader what to type, so every `sift` command and `--flag` they write in code must exist in the binary.
///
/// The command set is the parser's own dump of the command tree, the same source `GuideCommandReferenceTests` reads, so a command renamed or an option dropped fails the article that still teaches it. Prose is not read: only code spans and fenced blocks, outside HTML comments.
@Suite(.temporaryDirectories)
struct DocCCatalogTests {
    /// The articles this slice of the catalog is meant to contain, so a deleted or renamed one fails here instead of vanishing from the scan.
    static let expectedArticles: Set<String> = ["Sift.md", "GettingStarted.md", "Installing.md", "TheFourTools.md", "RunningBuildsAndTests.md", "HowTheHooksBehave.md", "Troubleshooting.md"]

    /// Every `sift <command>` written in a code span or block names a command the binary has.
    @Test
    func everyCommandInCodeExists() throws {
        let commands = try Set(GuideCommandReferenceTests.commandTree().map(\.name))
        var checked = 0

        for article in try Self.articles() {
            for segment in article.codeSegments {
                guard let command = segment.command else { continue }
                checked += 1

                #expect(commands.contains(command), "`sift \(command)` in \(article.name) is not a command of the binary")
            }
        }

        #expect(checked >= 10, "only \(checked) commands were checked")
    }

    /// Every `--flag` written in a code span or block is an option of the binary, and of the command beside it where the segment names one.
    @Test
    func everyFlagInCodeExists() throws {
        let commands = try GuideCommandReferenceTests.commandTree()
        let universal = Set(GuideCommandReferenceTests.exemptOptions.keys)
        let everyOption = commands.reduce(into: universal) { $0.formUnion($1.displayedOptions) }
        var checked = 0

        for article in try Self.articles() {
            for segment in article.codeSegments {
                let own = commands.first { $0.name == segment.command }.map { universal.union($0.displayedOptions) }
                for flag in segment.flags {
                    checked += 1

                    #expect(own?.contains(flag) ?? everyOption.contains(flag), "`\(flag)` in \(article.name) is not an option of \(segment.command.map { "`sift \($0)`" } ?? "the binary")")
                }
            }
        }

        #expect(checked >= 8, "only \(checked) flags were checked")
    }

    /// The scan finds the whole catalog, so an empty or shrunken folder cannot pass for a clean one.
    @Test
    func theCatalogHoldsTheExpectedArticles() throws {
        let names = try Set(Self.articles().map(\.name))

        #expect(Self.expectedArticles.isSubset(of: names), "missing from Docs/Sift.docc: \(Self.expectedArticles.subtracting(names).sorted())")
    }

    /// The padded sample the whole-read article quotes is long enough that the hook answers a whole read of it, with room to spare.
    ///
    /// The fixture is built by the script the article names, indexed, and its whole `Library.swift` read answered at the default context size. The source must be at least one and a half times the size where the margin crosses zero for that digest, so a small change to the rule's constants does not turn the article's reply into a read that runs.
    @Test
    func thePaddedSampleIsAnsweredAtTheDefaultContextSize() async throws {
        let root = try TemporaryDirectory.make("docs-fixture").appendingPathComponent("Shelf")
        let script = GuideCommandReferenceTests.repositoryRoot.appendingPathComponent("Distribution/docs-fixture.sh")
        try Self.run("/bin/sh", [script.path, root.path, "pad"])

        try await SiftEngine(directory: root).ensureFresh()
        let outcome = try await InPlaceAnswerTests.answer(.fileDigest(path: "Sources/Stacks/Library.swift"), from: root.path)

        guard case let .answered(answered) = outcome, let bytes = answered.calls.first?.bytes, let source = bytes.source else {
            Issue.record("the padded sample's whole read was not answered: \(outcome)")
            return
        }
        // The margin is linear in the file's size, so its zero is where the empty file's margin is made up.
        let slope = (1 - WholeReadWorth.wholeReReadShare) / WholeReadWorth.bytesPerToken
        let crossing = -WholeReadWorth.margin(fileBytes: 0, digestBytes: bytes.served, contextTokens: nil) / slope

        #expect(WholeReadWorth.isWorthTheTurn(fileBytes: source, digestBytes: bytes.served, contextTokens: nil))
        #expect(Double(source) >= 1.5 * crossing, "source \(source) B, margin crosses zero at \(Int(crossing)) B")
    }
}

private extension DocCCatalogTests {
    /// One article of the catalog, read as the code it contains.
    struct Article {
        let name: String
        let codeSegments: [CodeSegment]
    }

    /// One span, or one line of a fenced block: the unit in which a command and its flags stand together.
    struct CodeSegment {
        let text: String

        /// The words before a bare `--`, after which a line belongs to another tool (`sift run -- swift build --build-tests`).
        private var words: [Substring] {
            let all = text.split(whereSeparator: \.isWhitespace)
            return Array(all.prefix { $0 != "--" })
        }

        /// The word after `sift`, when it is written like a command name.
        var command: String? {
            let all = words
            guard let index = all.firstIndex(where: { $0 == "sift" || $0.hasSuffix("/sift") }), all.index(after: index) < all.endIndex else {
                return nil
            }
            let next = String(all[all.index(after: index)])
            return next.wholeMatch(of: /[a-z][a-z-]*/) == nil ? nil : next
        }

        /// Each `--long-option` written before any bare `--`, without trailing punctuation.
        var flags: [String] {
            words.flatMap { word in
                word.matches(of: /--[a-zA-Z][a-zA-Z0-9-]*/).map { String($0.output) }
            }
        }
    }

    /// Runs `executable` with `arguments`, failing the test where it exits non-zero.
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Every Markdown article in `Docs/Sift.docc`.
    static func articles() throws -> [Article] {
        let catalog = GuideCommandReferenceTests.repositoryRoot.appendingPathComponent("Docs/Sift.docc")
        let files = try FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try Article(name: $0.lastPathComponent, codeSegments: codeSegments(in: String(contentsOf: $0, encoding: .utf8))) }
    }

    /// The code spans and the lines of fenced blocks in a Markdown text, HTML comments removed first.
    static func codeSegments(in markdown: String) -> [CodeSegment] {
        let visible = markdown.replacing(/<!--[\s\S]*?-->/, with: "")
        var segments: [CodeSegment] = []
        var fenced = false

        for line in visible.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                fenced.toggle()
            } else if fenced {
                segments.append(CodeSegment(text: line.hasPrefix("$ ") ? String(line.dropFirst(2)) : String(line)))
            } else {
                segments += line.matches(of: /`([^`]+)`/).map { CodeSegment(text: String($0.output.1)) }
            }
        }
        return segments
    }
}
