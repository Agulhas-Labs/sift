//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A worktree never has an index store, so it never has callers — and what an answer says about that is the difference between a gap and a silent miss.
@Suite(.temporaryDirectories)
struct WorktreeSemanticsTests {
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Helper {
                func work() {}
                func unused() {}
            }
            """,
            to: "Sources/App/Helper.swift",
            in: root
        )
        try TestSources.write("func go() { Helper().work() }\n", to: "Sources/App/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }

    /// A linked worktree's note stays to one line and points at the help topic that carries the reasoning, rather than repeating the manual on every call — every builder agent works in a linked worktree, so the long form was being resent on every `where` and every `digest`.
    ///
    /// The reasoning itself — why the checkout's store is not borrowed, the build command, and the config key for a nested package — moves to `sift help worktree-index` rather than being dropped; ``HelpTopicsTests`` pins that it is still carried somewhere.
    @Test
    func aWorktreeIsToldInOneLineWhichPointsAtTheHelpTopic() async throws {
        let root = try Self.makeRepo()
        let worktree = try TestSources.makeWorktree(of: root, named: "agent-1a2b3c4d")
        let engine = try SiftEngine(directory: worktree)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "work()", freshness: freshness)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modeIndex = try #require(lines.firstIndex { $0.hasPrefix(DegradedNote.noStoreOpening) })
        let modeLine = lines[modeIndex]

        #expect(lines.first?.contains("semantic: none (no index store in this worktree)") == true)
        #expect(modeLine.contains("how to build one: sift help worktree-index"))
        // The long-form reasoning this used to carry inline is gone from the per-call note — it lives in the topic now.
        #expect(!modeLine.contains("NOT borrowed"))
        #expect(!modeLine.contains("sift run -- swift build"))
        // The note is exactly one of the answer's lines: the blank banner slot follows directly, not a
        // second notice line.
        #expect(lines[modeIndex + 1].isEmpty)
    }

    /// A checkout that has simply not been built is pointed at the topic carrying the recipe, never at the worktree reasoning, which is noise about a state it is not in.
    @Test
    func aCheckoutWithNoStoreKeepsThePlainInstruction() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "work()", freshness: freshness)

        #expect(output.contains("no store for callers, overrides or references; sites by written name; how to build one: sift help answers, section (index store)"), "\(output)")
        #expect(!output.contains(SiftEngine.buildCommandNote), "\(output)")
        #expect(!output.contains("linked worktree"))
    }

    /// A name that resolves to nothing would never have used the store, so a checkout with none is told in one line where the recipe is, not handed the recipe.
    @Test
    func aNoMatchOnACheckoutWithNoStoreGetsOnlyThePointerToTheRecipe() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "flaky", freshness: freshness)

        // A name that resolves to nothing lists no sites, so it carries no degraded note, only the pointer; the header says the store is absent.
        #expect(output.contains("semantic: none (no index store for this tree yet)"), "\(output)")
        #expect(output.contains("no store; how to build one: sift help answers, section (index store)"), "\(output)")
        #expect(!output.contains(SiftEngine.buildCommandNote), "\(output)")
        #expect(!output.contains("indexStorePath set in .sift.json"), "\(output)")
    }

    /// The recipe is carried once, by the `answers` topic's `(index store)` section, quoted from the same strings a per-call note uses.
    @Test
    func theAnswersTopicCarriesTheRecipeUnderIndexStore() throws {
        let body = try #require(HelpTopics.topic(named: "answers")).body

        #expect(body.contains("(index store)"))
        #expect(body.contains(SiftEngine.buildCommandNote))
        #expect(body.contains(SiftEngine.nestedStoreClause))
    }

    /// The gap that makes a rename sweep dangerous — an empty caller list under a syntactic answer must not read as "nothing uses this" — is now said once, in `sift help worktree-index`, rather than in a paragraph repeated on every call; the per-call notice is one line pointing at the mode line above it.
    @Test
    func anAnswerWithNoStoreKeepsTheNoticeToOneLine() async throws {
        let root = try Self.makeRepo()
        let worktree = try TestSources.makeWorktree(of: root, named: "sweep")
        let engine = try SiftEngine(directory: worktree)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "unused()", freshness: freshness)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let noticeIndex = try #require(lines.firstIndex { $0.hasPrefix(DegradedNote.noStoreOpening) })
        let notice = lines[noticeIndex]

        #expect(notice.contains("sites by written name"))
        #expect(!notice.contains("never as \"nothing uses this\""))
        #expect(!notice.contains("a type named in an annotation"))
        // The notice is exactly one of the answer's lines: the blank banner slot, then the result, follow directly.
        #expect(lines[noticeIndex + 1].isEmpty)
        #expect(lines[noticeIndex + 2].hasPrefix("declarations ("))
    }

    /// A caveat below the content is a caveat read after the decision, so the notice sits above the answer it qualifies.
    @Test
    func theNoticeStandsAboveTheAnswerItQualifies() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "work()", freshness: freshness)
        let notice = try #require(output.range(of: DegradedNote.noStoreOpening))
        let declarations = try #require(output.range(of: "declarations ("))

        #expect(notice.lowerBound < declarations.lowerBound)
    }
}
