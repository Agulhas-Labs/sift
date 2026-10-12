//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Covers the script that keeps a release bundle's relative links pointing at something the bundle holds.
///
/// It runs on documents written here, in a folder this suite owns: a titled link is read as target and title, and a link-shaped run of characters in a code span or a fenced block is prose about links, so neither mode touches it.
@Suite(.temporaryDirectories)
struct BundleLinksScriptTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent() // SiftCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // the repository root

    private static let script = repository.appending(path: "Distribution/bundle-links.sh").path
    private static var repositoryURL: String {
        "https://github.com/Agulhas-Labs/sift/blob/v1.2.3"
    }

    /// Runs the script with no `GIT_*` variable in its environment, feeding `input` on standard input.
    private static func run(_ arguments: [String], input: String = "") throws -> Outcome {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let printed = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Outcome(status: process.terminationStatus, output: String(data: printed, encoding: .utf8) ?? "")
    }

    private static func rewrite(_ text: String, from source: String = "README.md") throws -> String {
        try run(["rewrite", source, "1.2.3"], input: text).output
    }

    /// A staged bundle holding one document, `text`, at `README.md`, and the folder it sits in.
    private static func stage(_ text: String) throws -> URL {
        let root = try TemporaryDirectory.make("bundle-links").appending(path: "bundle-links")
        try FileManager.default.createDirectory(at: root.appending(path: "Docs"), withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "guide\n".write(to: root.appending(path: "Docs/Guide.md"), atomically: true, encoding: .utf8)

        return root
    }

    /// A target in angle brackets is rewritten without the brackets, a space in it percent-encoded, and a title after it stays as written.
    @Test
    func anAngleBracketTargetIsRewrittenWithoutTheBrackets() throws {
        let rewritten = try Self.rewrite("[a](<Docs/Guide.md>) [b](<Docs/Design.md>) [c](<Docs/My Notes.md> \"t\")\n")

        #expect(rewritten == "[a](Docs/Guide.md) [b](\(Self.repositoryURL)/Docs/Design.md) [c](\(Self.repositoryURL)/Docs/My%20Notes.md \"t\")\n")
    }

    /// A code span opened on one line and closed on the next is code to the rewrite too, so the link-shaped text inside it stays as written while a link after it is rewritten.
    @Test
    func aCodeSpanRunningAcrossLinesIsLeftAloneByTheRewrite() throws {
        let rewritten = try Self.rewrite("see `x\ny](Docs/Design.md) z` and [a](Docs/Design.md)\n")

        #expect(rewritten == "see `x\ny](Docs/Design.md) z` and [a](\(Self.repositoryURL)/Docs/Design.md)\n")
    }

    /// An indented code block holds literal text, so the rewrite leaves a link in it alone, and a stray backtick does not carry past a heading or a break.
    @Test
    func theRewriteReadsBlockEdgesAsTheCheckDoes() throws {
        let code = try Self.rewrite("text\n\n    [g](Docs/Design.md)\n")
        let edges = try Self.rewrite("# Use `x\n[g](Docs/Design.md) `y`\n\nrun `sift\n***\nsee [g](Docs/Design.md) and `x`\n")

        #expect(code == "text\n\n    [g](Docs/Design.md)\n")
        #expect(edges == "# Use `x\n[g](\(Self.repositoryURL)/Docs/Design.md) `y`\n\nrun `sift\n***\nsee [g](\(Self.repositoryURL)/Docs/Design.md) and `x`\n")
    }

    /// A target in angle brackets cannot run across a line, so a broken one is left as written and a whole target on the next line is still rewritten.
    @Test
    func anAngleBracketTargetSplitAcrossLinesIsLeftAlone() throws {
        let rewritten = try Self.rewrite("[a](<Docs/My\nNotes.md>) text\n[b](<Docs/Guide.md>)\n")

        #expect(rewritten == "[a](<Docs/My\nNotes.md>) text\n[b](Docs/Guide.md)\n")
    }

    /// A target is the part before the title, so a link to a shipped document stays in the bundle and any other goes to the public repository, in each case keeping the title as written.
    @Test
    func aTitleIsNotPartOfTheTarget() throws {
        let shipped = try Self.rewrite("[a](Docs/Guide.md \"t\") [b](Docs/Guide.md#x 'u') [c](Docs/Guide.md (v))\n")
        let unshipped = try Self.rewrite("[a](Docs/Design.md \"t\") [b](Docs/Design.md 'u') [c](Docs/Design.md (v))\n")

        #expect(shipped == "[a](Docs/Guide.md \"t\") [b](Docs/Guide.md#x 'u') [c](Docs/Guide.md (v))\n")
        #expect(unshipped == "[a](\(Self.repositoryURL)/Docs/Design.md \"t\") [b](\(Self.repositoryURL)/Docs/Design.md 'u') [c](\(Self.repositoryURL)/Docs/Design.md (v))\n")
    }

    /// A link with no title, in prose beside a code span, still rewrites as it always did.
    @Test
    func anUntitledLinkIsRewrittenAsBefore() throws {
        let rewritten = try Self.rewrite("[a](Docs/Guide.md) [b](Docs/Design.md#top) [c](https://example.com/x) [d](#here)\n")

        #expect(rewritten == "[a](Docs/Guide.md) [b](\(Self.repositoryURL)/Docs/Design.md#top) [c](https://example.com/x) [d](#here)\n")
    }

    /// Link-shaped text in a code span or a fenced block comes out as it went in, while a real link on the same line or after the block is rewritten.
    @Test
    func codeSpansAndFencedBlocksAreLeftAlone() throws {
        let document = """
        A `x](Docs/Design.md` span and [real](Docs/Design.md) link, ``a`](Docs/Design.md`` too.
        ```
        z](Docs/Design.md)
        ```
        ~~~sh
        z](Docs/Design.md)
        ~~~
        after [real](Docs/Design.md)

        """
        let expected = """
        A `x](Docs/Design.md` span and [real](\(Self.repositoryURL)/Docs/Design.md) link, ``a`](Docs/Design.md`` too.
        ```
        z](Docs/Design.md)
        ```
        ~~~sh
        z](Docs/Design.md)
        ~~~
        after [real](\(Self.repositoryURL)/Docs/Design.md)

        """

        #expect(try Self.rewrite(document) == expected)
    }

    /// The check ignores a link-shaped run in a code span or a fenced block, still fails on a real dead link, and reads a titled link by its target.
    @Test
    func theCheckIgnoresCodeAndReadsTitles() throws {
        let clean = try Self.stage("`x](nowhere.md` and [g](Docs/Guide.md \"t\")\n```\nz](nowhere.md)\n```\n")
        let dead = try Self.stage("[g](nowhere.md \"t\") `x](Docs/Guide.md`\n")

        let passed = try Self.run(["check", clean.path])
        let failed = try Self.run(["check", dead.path])

        #expect(passed.status == 0, "\(passed.output)")
        #expect(passed.output.contains("1 relative checked, 0 unresolved"), "\(passed.output)")
        #expect(failed.status == 1)
        #expect(failed.output.contains("unresolved link in README.md: nowhere.md"), "\(failed.output)")
    }

    /// A document with Windows line endings closes its fence like any other, so a dead link after it is still reported.
    @Test
    func aFenceClosesOnALineEndingInACarriageReturn() throws {
        let staged = try Self.stage("```swift\r\ncode\r\n```\r\nsee [x](nowhere.md)\r\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: nowhere.md"), "\(outcome.output)")
    }

    /// A line that starts with an inline code span in triple backticks is prose, not a fence, so a dead link after it is still reported.
    @Test
    func aTripleBacktickSpanAtLineStartDoesNotOpenAFence() throws {
        let staged = try Self.stage("```foo``` and more\n[x](nowhere.md)\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: nowhere.md"), "\(outcome.output)")
    }

    /// A fence still open at the end of a document is named in a warning, and the check does not fail on that alone.
    @Test
    func anUnclosedFenceWarnsWithoutFailing() throws {
        let staged = try Self.stage("```\n[x](nowhere.md)\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(outcome.output.contains("warning: README.md: a code fence is still open"), "\(outcome.output)")
    }

    /// A target in angle brackets may hold a space, and the check resolves what is inside the brackets.
    @Test
    func anAngleBracketTargetIsReadInsideTheBrackets() throws {
        let staged = try Self.stage("[a](<Docs/Guide.md>) [b](<nowhere at all.md>)\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: nowhere at all.md"), "\(outcome.output)")
        #expect(outcome.output.contains("2 relative checked, 1 unresolved"), "\(outcome.output)")
    }

    /// A code span that runs across two lines of a paragraph hides the link-shaped text inside it, while a dead link after the paragraph break is still reported.
    @Test
    func aCodeSpanMayRunAcrossLines() throws {
        let staged = try Self.stage("see `x\ny](nowhere.md) z` here\n\n[dead](missing.md)\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: missing.md"), "\(outcome.output)")
        #expect(!outcome.output.contains("nowhere.md"), "\(outcome.output)")
    }

    /// A stray backtick in a heading, list item, table row or quote does not pair with one in a later block, so the dead link between them is still reported.
    @Test(arguments: [
        "- run `sift\n- see [g](Missing.md) and `x`\n",
        "# Use `x\n[g](Missing.md) `y`\n",
        "| a | `b |\n| [g](Missing.md) | `c` |\n",
        "> quote `x\n> [g](Missing.md) `y`\n",
    ])
    func aStrayBacktickDoesNotCrossABlock(document: String) throws {
        let staged = try Self.stage(document)

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: Missing.md"), "\(outcome.output)")
    }

    /// A stray backtick does not carry across a nested list item, a thematic break, a setext underline or an indented code block, so the dead link beyond it is still reported.
    @Test(arguments: [
        "- run `sift\n    - see [g](Missing.md) and `x`\n",
        "run `sift\n***\nsee [g](Missing.md) and `x`\n",
        "run `sift\n___\nsee [g](Missing.md) and `x`\n",
        "run `sift\n---\nsee [g](Missing.md) and `x`\n",
        "run `sift\n===\nsee [g](Missing.md) and `x`\n",
        "    code `x\nsee [g](Missing.md) and `y`\n",
    ])
    func aStrayBacktickDoesNotCrossABlockEdge(document: String) throws {
        let staged = try Self.stage(document)

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: Missing.md"), "\(outcome.output)")
    }

    /// A link in an indented code block is not a link, and a paragraph continued in a list item after a blank line is still read.
    @Test
    func anIndentedCodeBlockHoldsNoLinksButAListItemsParagraphDoes() throws {
        let code = try Self.stage("text\n\n    [g](Nowhere.md)\n")
        let item = try Self.stage("- a\n\n    [g](Missing.md)\n")

        let codeOutcome = try Self.run(["check", code.path])
        let itemOutcome = try Self.run(["check", item.path])

        #expect(codeOutcome.status == 0, "\(codeOutcome.output)")
        #expect(itemOutcome.status == 1, "\(itemOutcome.output)")
    }

    /// A code span may still run across the continuation lines of one list item.
    @Test
    func aCodeSpanMayRunAcrossAListItemsLines() throws {
        let staged = try Self.stage("- see `x\n  y](Nowhere.md) z` here\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 0, "\(outcome.output)")
    }

    /// Indented code starts four columns past the content column of the list item a line sits in, so a paragraph indented four spaces in an item whose text starts at column two or three is still read, after another paragraph of the item.
    @Test(arguments: [
        "- a\n\n  b\n\n    [g](Missing.md)\n",
        "1. a\n\n   b\n\n    [g](Missing.md)\n",
    ])
    func aParagraphInAListItemIsNotIndentedCode(document: String) throws {
        let staged = try Self.stage(document)

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: Missing.md"), "\(outcome.output)")
    }

    /// A list item nested under a continuation paragraph of an item opens a block of its own, so a stray backtick in that paragraph does not hide the dead link in it.
    @Test(arguments: [
        "- a\n\n    cont `x\n    - n [g](Missing.md) `y`\n",
        "10. a\n\n    cont `x\n    - n [g](Missing.md) `y`\n",
    ])
    func aNestedItemEndsAContinuationParagraph(document: String) throws {
        let staged = try Self.stage(document)

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: Missing.md"), "\(outcome.output)")
    }

    /// A fence line four or more columns past the content column a line sits in is indented code or a paragraph's continuation, not a fence, so the dead link after it is still reported.
    @Test(arguments: [
        "Write a fence:\n\n    ```\n\nThen see [g](Missing.md).\n\n```swift\nlet x = 1\n```\n",
        "text\n        ```\nmore [g](Missing.md)\n",
        "- a\n\n      ```\n\nmore [g](Missing.md)\n",
    ])
    func anIndentedFenceLineOpensNoFence(document: String) throws {
        let staged = try Self.stage(document)

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 1, "\(outcome.output)")
        #expect(outcome.output.contains("unresolved link in README.md: Missing.md"), "\(outcome.output)")
    }

    /// The rewrite reads an indented fence line as the check does, so the link after it is rewritten and the real fence below stays as written.
    @Test
    func theRewriteReadsAnIndentedFenceLineAsCode() throws {
        let rewritten = try Self.rewrite("Write a fence:\n\n    ```\n\nThen see [g](Docs/Design.md).\n\n```swift\n[h](Docs/Design.md)\n```\n")

        #expect(rewritten == "Write a fence:\n\n    ```\n\nThen see [g](\(Self.repositoryURL)/Docs/Design.md).\n\n```swift\n[h](Docs/Design.md)\n```\n")
    }

    /// A heading on a list item's marker line is a block of its own, so a stray backtick in it does not hide the link in the item's next line.
    @Test
    func aHeadingOnAListMarkerLineEndsAtTheLine() throws {
        let rewritten = try Self.rewrite("- # T `x\n  [g](Docs/Design.md) `y`\n")

        #expect(rewritten == "- # T `x\n  [g](\(Self.repositoryURL)/Docs/Design.md) `y`\n")
    }

    /// A fence opened on a list item's marker line holds code, so a link in it stays as written and the link after it is rewritten.
    @Test
    func aFenceOnAListMarkerLineHoldsCode() throws {
        let rewritten = try Self.rewrite("- ```\n  [g](Docs/Design.md)\n  ```\n\nSee [h](Docs/Design.md)\n")

        #expect(rewritten == "- ```\n  [g](Docs/Design.md)\n  ```\n\nSee [h](\(Self.repositoryURL)/Docs/Design.md)\n")
    }

    /// Text five or more columns past a list marker is an indented code block that starts the item, so a link in it stays as written.
    @Test
    func indentedCodeOnAListMarkerLineIsLeftAlone() throws {
        let rewritten = try Self.rewrite("-     [g](Docs/Design.md)\n")

        #expect(rewritten == "-     [g](Docs/Design.md)\n")
    }

    /// A document the check cannot read fails it with a message, rather than passing having checked nothing.
    @Test
    func anUnreadableDocumentFailsTheCheck() throws {
        let staged = try Self.stage("[x](nowhere.md)\n")
        let document = staged.appending(path: "README.md").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: document)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document) }

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 2, "\(outcome.output)")
        #expect(outcome.output.contains("error: README.md: failed while reading the document"), "\(outcome.output)")
        #expect(!outcome.output.contains("0 unresolved"), "\(outcome.output)")
    }

    /// The check cuts a target at a tab before the title, as the rewrite does.
    @Test
    func aTabBeforeATitleEndsTheTarget() throws {
        let staged = try Self.stage("[g](Docs/Guide.md\t\"t\")\n")

        let outcome = try Self.run(["check", staged.path])

        #expect(outcome.status == 0, "\(outcome.output)")
        #expect(outcome.output.contains("1 relative checked, 0 unresolved"), "\(outcome.output)")
    }
}

private extension BundleLinksScriptTests {
    /// What a run printed and how it ended.
    struct Outcome {
        let status: Int32
        let output: String
    }
}
