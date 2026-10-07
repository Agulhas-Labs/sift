//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the door beside the one the shell hook closes: a `Grep` that asks the refused question with different arguments.
@Suite(.temporaryDirectories)
struct SearchToolAdviceTests {
    private static func temporary() throws -> Harness {
        let root = try TemporaryDirectory.make("grepadvice")
            .appendingPathComponent("grepadvice", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: sources.appendingPathComponent("View.swift"))
        return Harness(root: root, cleanup: { try? FileManager.default.removeItem(at: root) })
    }

    /// The three markers that say "Swift" without needing the filesystem, each mapping to the call the shell form would have got.
    @Test
    func anExplicitSwiftFilterIsAdvisedWithoutResolvingAnything() {
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "UsageLog", "type": "swift"])?.call == "where UsageLog")
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "UsageLog", "glob": "**/*.swift"])?.call == "where UsageLog")
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: [
            "pattern": "func refresh",
            "path": "Sources/App/SummaryState.swift",
        ])?.call == "digest SummaryState.refresh")
    }

    /// A search of a `.swift` file with nothing symbol-shaped to go on still has an answer: the file's shape.
    @Test
    func aFileSearchWithNoSymbolFallsBackToTheFilesDigest() {
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: [
            "pattern": "->",
            "path": "Sources/App/SummaryState.swift",
        ])?.call == "digest SummaryState")
    }

    /// Nothing about Swift and nothing to resolve: not this tool's business.
    @Test
    func anUnmarkedSearchWithNoDirectoryIsLeftAlone() {
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "UsageLog", "path": "Sources"]) == nil)
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "TODO", "glob": "*.md"]) == nil)
    }

    /// The unmarked case, resolved: the same two gates the shell uses, so which surface the search went through cannot change the answer.
    @Test
    func anUnmarkedSearchOfASwiftTreeIsAdvisedOnlyForASymbol() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }

        #expect(SearchToolAdvice.suggestion(
            tool: "Grep",
            input: ["pattern": "UsageLog", "path": "Sources"],
            in: harness.path
        )?.call == "where UsageLog")
        #expect(SearchToolAdvice.suggestion(
            tool: "Grep",
            input: ["pattern": "revisit this later", "path": "Sources"],
            in: harness.path
        ) == nil)
    }

    /// `path` is optional on the tool — omitting it searches the working directory, which is the commonest form of all.
    @Test
    func anOmittedPathMeansTheWorkingDirectory() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }

        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "UsageLog"], in: harness.path)?.call == "where UsageLog")
    }

    /// A `Glob` asks which files exist; the index answers that with what is *in* them, which is the better answer to the same question.
    @Test
    func aSwiftGlobIsAdvisedByWhatItIsHunting() {
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "**/*.swift"])?.call == "digest .")
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "Sources/**/*.swift"])?.call == "digest .")
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "**/*Store.swift"])?.call == "search path:Store")
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "**/Model*.swift"])?.call == "search path:Model")
    }

    /// A glob for anything else is none of this tool's business, and neither is a tool it does not cover.
    @Test
    func aNonSwiftGlobAndAnUnknownToolAreLeftAlone() {
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "**/*.md"]) == nil)
        #expect(SearchToolAdvice.suggestion(tool: "Glob", input: ["pattern": "Package.resolved"]) == nil)
        #expect(SearchToolAdvice.suggestion(tool: "WebFetch", input: ["pattern": "**/*.swift"]) == nil)
    }

    /// The metric and the hook must be one judgement, not two that agree by inspection — a metric keyed on the path counts every `Grep` in a repo whose *path* holds the word "swift", and none at all in one that does not.
    @Test
    func classifyingALookupIsTheSameQuestionAsAdvisingOnIt() {
        let swiftish: [String: Any] = ["pattern": "UsageLog", "type": "swift"]
        let prose: [String: Any] = ["pattern": "TODO", "glob": "*.md"]

        #expect(SearchToolAdvice.isSwiftLookup(tool: "Grep", input: swiftish))
        #expect(!SearchToolAdvice.isSwiftLookup(tool: "Grep", input: prose))
        // The path holding "Sift" is not evidence about what was searched for.
        #expect(!SearchToolAdvice.isSwiftLookup(tool: "Grep", input: ["pattern": "usage", "path": "/repos/Sift/Docs"]))
    }

    /// A glob that opens on `!` excludes the tree rather than confining the search to it: `!**/Pods/**` rules `Pods` *out*, exactly as the shell's own `-g '!**/Pods/**'` does, so it never stands as the path that narrows a search to outside the indexed sources.
    @Test
    func aNegatedGlobDoesNotConfineASearchOutsideTheIndexedSources() {
        let input: [String: Any] = ["output_mode": "content", "pattern": "Depot", "path": "Sources/View.swift", "glob": "!**/Pods/**"]

        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: input) == nil)
    }
}

private extension SearchToolAdviceTests {
    /// A throwaway tree with one Swift file in it, and the tidy-up.
    struct Harness {
        let root: URL
        let cleanup: () -> Void

        var path: String {
            root.path
        }
    }
}
