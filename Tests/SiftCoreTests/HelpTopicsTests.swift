//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `Sift.md` sends a reader to `sift help`, which lists the topics holding the material moved out of the always-loaded rule; this is what keeps that pointer honest.
struct HelpTopicsTests {
    private static var repository: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // the repository root
    }

    /// Every topic name `Sift.md` points a reader at is one `HelpTopics` actually carries.
    ///
    /// A rewrite of the rule that renames or drops a topic without updating `HelpTopics` to match would otherwise read as reference material that silently is not there — the caller follows the pointer and `sift help` refuses it. Scanning the rule's own text rather than hand-listing its topic names here is what keeps this pinned to whatever the rule actually says, not to what it said when this test was written.
    @Test
    func everyTopicSiftMDNamesExists() throws {
        let text = try String(contentsOf: Self.repository.appendingPathComponent("Sift.md"), encoding: .utf8)
        let pattern = try Regex(#"`sift help ([a-z][a-z0-9-]*)`"#)
        let named = Set(text.matches(of: pattern).compactMap { $0.output[1].substring.map(String.init) })

        #expect(!named.isEmpty)
        for name in named {
            #expect(HelpTopics.topic(named: name) != nil, "Sift.md points at `sift help \(name)`, which no topic carries")
        }
    }

    /// The rule does not name every topic: it names `sift help`, which lists them, so a topic added to `HelpTopics` is reached without a rule edit.
    ///
    /// What this pins is the pointer the rule relies on: it says `sift help` lists the topics, and there are topics to list.
    @Test
    func theRuleNamesSiftHelpAsTheListOfTopics() throws {
        let text = try String(contentsOf: Self.repository.appendingPathComponent("Sift.md"), encoding: .utf8)

        #expect(text.contains("`sift help` lists the topics"))
        #expect(!HelpTopics.all.isEmpty)
    }

    /// Guidance the rule carried before it was split is still carried — in the rule or in a topic — rather than lost between the two.
    ///
    /// Moving text is where it goes missing: each of these was once dropped by a rewrite that meant only to shorten, and none of them is something a reader would think to ask `sift help` for. Line breaks and continuations are folded before matching, so a phrase is found wherever its wrap fell.
    @Test
    func guidanceTheSplitMovedIsStillCarried() throws {
        let rule = try String(contentsOf: Self.repository.appendingPathComponent("Sift.md"), encoding: .utf8)
        let carried = ([rule] + HelpTopics.all.map(\.body)).joined(separator: "\n")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let phrases = [
            "since the CLI does not depend on the server at all",
            "by checking each recorded process against the start time the kernel holds for it",
            "plus when and why the last one stopped",
            "and the shell is where they are most often skipped",
            "or a name no index declares",
            "is answered in place, or let through",
            "a shell command, a Grep, a Glob, or a whole-file Read",
            "not a wall and not a permission problem",
            "Take the suggestion when it fits — usually it is the shorter path anyway",
            "Reaching for Read because a file \"looks small\" is the one case that is always wasted",
            "views are the biggest files in an app repo and the most wasteful to read whole",
            "the one-call version of the digest-then-ranged-Read loop",
            "Grep cannot answer these reliably because the pattern spans nesting and line breaks",
            "\"every class conforming to `X` that force-unwraps\", \"every async function that never awaits\"",
            "by value (any language, case-insensitive) or key",
            "and the answer lists them above its own list for that reason",
            "a worktree has no build directory of its own",
            "The obvious repair is the one thing this must never do: read the checkout's store instead",
            "That store describes a *different tree*",
            "it would name callers that do not exist here, and miss ones that do",
            "the checkout's store is never borrowed, on any query, however current it looks",
            "sift run -- swift build --build-tests for a SwiftPM package at the root",
            "needs indexStorePath set in .sift.json",
            "Running the same query against the repository's own checkout is a perfectly good answer",
            "folds in the uses written through the typealiases of it the index holds",
            "a use under any other name, an alias declared inside a function body or a string literal, is invisible to it",
            "An empty list here is never \"nothing uses this\"",
            "A gate that matches `totals: ✘ failed` must match `crashed` too, or match `^totals: ✘`",
        ]

        for phrase in phrases {
            #expect(carried.contains(phrase), "neither Sift.md nor any help topic carries: \(phrase)")
        }
    }

    /// The `answers` topic describes `status`'s own stale form in the words `status` actually prints, so a reader who meets it can look it up.
    @Test
    func theAnswersTopicDescribesStatusesStaleFormAsItIsPrinted() throws {
        let answers = try #require(HelpTopics.topic(named: "answers")).body
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let template = "stale since last build (N files: C changed, D deleted)"
        let printed = SemanticAxis.staleByFileState(StaleFiles(changed: 2, deleted: 3)).rendered

        #expect(answers.contains("`\(template)`"))
        #expect(template.replacingOccurrences(of: "N files", with: "5 files").replacingOccurrences(of: "C changed", with: "2 changed").replacingOccurrences(of: "D deleted", with: "3 deleted") == printed)
    }
}
