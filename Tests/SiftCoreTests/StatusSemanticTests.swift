//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `status`'s own semantic axis against a really built index store: the health command has to see what a query in the same tree would see, not the syntactic default a query never tried past.
///
/// Every query here is asked again while the store is still loading (``SemanticStoreWarmUp``), because a `warming` answer is a statement about the machine's load rather than about the axis these tests compare.
@Suite(.temporaryDirectories)
struct StatusSemanticTests {
    /// `status` alone, with no prior query in this engine, must already report the store a query would load — judged from discovery and file state, without opening it.
    ///
    /// The bug this pins was `status` saying `syntactic-only` over a store a `where` in the same tree answered from, because nothing on the status path ever looked for one. Over a real, openable store, so that "never opened" is checked where an open would have left its trace: the ingestion cache under `.sift/isdb`.
    @Test
    func statusAloneReportsTheStoreAQueryWouldLoad() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("semantic: fresh"))
        #expect(!status.contains("semantic: syntactic-only"))
        #expect(!FileManager.default.fileExists(atPath: Self.ingestionCache(in: root).path))
    }

    /// Where an open of the index store leaves its ingestion cache — the one trace an open cannot avoid leaving, and so the thing a test of "never opens" has to look for.
    private static func ingestionCache(in root: URL) -> URL {
        SiftPaths.cache(in: root).appendingPathComponent("isdb")
    }

    /// The same tree and head `where` reports `fresh` for, `status` must report identically — the exact disagreement the bug was found from.
    @Test
    func statusAgreesWithAQueryInTheSameEngine() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let queried = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "helper()", freshness: freshness) }
        let status = try engine.statusText(freshness: freshness)

        #expect(queried.contains("semantic: fresh"))
        #expect(status.contains("semantic: fresh"))
    }

    /// With no index store at all, `status` still says so plainly rather than opening one that is not there — and its header points at the line that says it.
    ///
    /// A query's header says "see note" over a note directly beneath it; `status` has no such note, only its own `index store:` line further down, so pointing at "note" there sends the reader looking for something that is not there.
    @Test
    func statusWithNoStoreStillSaysNone() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)
        let lines = status.split(separator: "\n").map(String.init)

        // The state, not its wording: the words for "no store" are the header's to choose, and a test pinned to
        // them would fail on a rewording that changed nothing this checks.
        #expect(lines.first?.hasSuffix("semantic: \(SemanticAxis.noStoreInStatus.rendered)") == true)
        #expect(!status.contains("see note"))
        #expect(lines.dropFirst().contains { $0.hasPrefix("index store: none found") })
    }

    /// The exact reproduction the bug was found from: build, edit one file, and `status` must say precisely what a query over the same tree says — not `fresh`, which is what it claimed before this fix, and not something merely similar: the same words.
    @Test
    func statusAgreesWithAQueryOverATreeEditedAfterTheBuild() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        // Edit Base.swift after the build, exactly as SemanticWhereTests.editedFileRefusesPerSymbolWhileOthersStillAnswer does.
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
                public func added() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        let freshness = try await engine.ensureFresh()

        let greet = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "greet()", freshness: freshness) }
        let status = try engine.statusText(freshness: freshness)

        #expect(greet.contains("semantic: stale (1 file changed since last build)"))
        #expect(status.contains("semantic: stale (1 file changed since last build)"))
    }

    /// `status` must never open the index store to answer — a discovered store this call would corrupt an open of (an empty `v5/units`, no real index-store-db content) still answers promptly, from file state alone, because opening it for real is the one thing this path must never do.
    @Test
    func statusNeverAttemptsToOpenTheStoreItDiscovers() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        // Discovery takes only a directory holding `v<N>/units` for a store; one with nothing else is the least
        // that still reads as one.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/index/store/v5/units"),
            withIntermediateDirectories: true
        )
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        // The units directory holds no unit, so there is no build for the one indexed file to be newer than.
        #expect(status.contains("semantic: stale (1 file changed since last build)"))
        #expect(status.contains("index store: .build"))
        // Answering from file state is not enough on its own: an implementation that also opened the store would
        // pass every line above, and only the cache an open writes tells the two apart.
        #expect(!FileManager.default.fileExists(atPath: Self.ingestionCache(in: root).path))
    }

    /// The note under the header is short sentences in the reader's words, and names each case this reading can miss — a query still shows every one, so leaving one out would let `fresh` stand with nothing to say otherwise.
    @Test
    func theNoteUnderTheHeaderNamesEveryGapInShortPlainSentences() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Widget {}\n", to: "Sources/App/Widget.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/index/store/v5/units"),
            withIntermediateDirectories: true
        )
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let lines = try engine.statusText(freshness: freshness).split(separator: "\n").map(String.init)
        let note = Array(lines.dropFirst().prefix { !$0.hasPrefix("root: ") })

        #expect(note == SiftEngine.statusAxisNote)
        for line in note {
            #expect(line.count <= 170, "\(line)")
            #expect(!["ledger", "anchor", "unit"].contains { line.contains($0) }, "\(line)")
            #expect(!line.contains("upgraded"), "\(line)")
        }
        let text = note.joined(separator: " ")
        for gap in [
            "a declaration the store has no record of", "unbuilt test files", "fails to open", "still loading", "without cleaning",
            "never tracked", "fast-forward", "starts only once",
        ] {
            #expect(text.contains(gap), "the note does not name: \(gap)")
        }
    }

    /// Build, delete a file, and `status` must see what a query over the same tree sees: the store still cites a file the tree no longer has.
    ///
    /// The same fact in the same count, worded one step weaker — `status` never read an occurrence, so it cannot say the store holds one in the file, only that the file was here and is gone.
    @Test
    func statusAgreesWithAQueryOverATreeWithAFileDeletedAfterTheBuild() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        let freshness = try await engine.ensureFresh()

        let greet = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "greet()", freshness: freshness) }
        let status = try engine.statusText(freshness: freshness)

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: stale (1 file deleted since last build)"))
    }

    /// `sift reset` between a deletion and the next query loses the ledger's only record of it — the fresh store's first full index never held a row for `Caller.swift` to drop, so `deleteFiles` alone cannot see the deletion.
    ///
    /// Seeded from git's tracked-but-missing files instead, `status` and `where` must still agree afterwards, exactly as they do with no reset in between.
    @Test
    func statusAgreesWithAQueryAfterAResetLosesTheLedger() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        _ = try await engine.ensureFresh()
        // Wipes sift's own store — and with it the ledger's only record of the deletion above — without
        // touching the real build's index store, which still cites the call site inside the file that is gone.
        _ = try SiftEngine.reset(directory: root)

        let fresh = try SiftEngine(directory: root)
        let freshness = try await fresh.ensureFresh()
        let greet = try await SemanticStoreWarmUp.settled { try await fresh.lookup(symbol: "greet()", freshness: freshness) }
        let status = try fresh.statusText(freshness: freshness)

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: stale (1 file deleted since last build)"))
    }

    /// `git rm` takes the file out of what git tracks as well as off the disk, so after a reset no tracked-but-missing path names it — only the staged deletion still does.
    @Test
    func statusAgreesWithAQueryAfterAResetFollowingAGitRm() async throws {
        let (greet, status) = try await Self.axesAfterAReset { root in
            try TestSources.runGit(["rm", "-q", "Sources/Lib/Caller.swift"], in: root)
        }

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: stale (1 file deleted since last build)"))
    }

    /// Once the deletion is committed git stages nothing either, and only the history since the build still names it.
    @Test
    func statusAgreesWithAQueryAfterAResetFollowingACommittedDeletion() async throws {
        let (greet, status) = try await Self.axesAfterAReset { root in
            try TestSources.runGit(["rm", "-q", "Sources/Lib/Caller.swift"], in: root)
            try TestSources.commitAll(in: root, message: "delete the caller")
        }

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: stale (1 file deleted since last build)"))
    }

    /// A store written by a binary from before the ledger, which noticed a deletion and dropped the file's rows without recording it, is upgraded in place rather than rebuilt — so a full index never runs to seed it, and the first query under the new binary has to.
    @Test
    func statusAgreesWithAQueryOverAStoreWrittenBeforeTheLedger() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        try DeletionLedgerTests.dropRowsAsABinaryFromBeforeTheLedger(paths: ["Sources/Lib/Caller.swift"], in: root)

        let upgraded = try SiftEngine(directory: root)
        let freshness = try await upgraded.ensureFresh()
        let status = try upgraded.statusText(freshness: freshness)
        let greet = try await SemanticStoreWarmUp.settled { try await upgraded.lookup(symbol: "greet()", freshness: freshness) }

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: stale (1 file deleted since last build)"))
    }

    /// The residual the once-only seed cannot close.
    ///
    /// This engine's own first read already seeded the ledger (there was nothing missing yet, so it seeded empty), and only afterward does an older-than-the-ledger binary drop `Caller.swift`'s rows — a real deployment shape, since an MCP server started before an install keeps running the code it was started with. The seed never runs twice, so nothing records this drop, and `status` reads `fresh` while a query still sees the file gone. Ruled acceptable rather than reseeded (Docs/Design.md §2) — named in the note instead.
    @Test
    func statusStaysFreshWhenAnOlderBinaryDropsAfterTheLedgerIsAlreadySeeded() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: root).ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Caller.swift"))
        try DeletionLedgerTests.dropRowsWithoutTouchingAnExistingLedger(paths: ["Sources/Lib/Caller.swift"], in: root)

        let reread = try SiftEngine(directory: root)
        let freshness = try await reread.ensureFresh()
        let greet = try await SemanticStoreWarmUp.settled { try await reread.lookup(symbol: "greet()", freshness: freshness) }
        let status = try reread.statusText(freshness: freshness)

        #expect(greet.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(status.contains("semantic: fresh"))
    }

    /// Build, index, `delete`, reset — then what a query and `status` each report of `greet()` from the fresh store the reset left behind.
    private static func axesAfterAReset(delete: (URL) throws -> Void) async throws -> (query: String, status: String) {
        let root = try SemanticWhereTests.makeBuiltRepo()
        _ = try await SiftEngine(directory: root).ensureFresh()
        try delete(root)
        _ = try SiftEngine.reset(directory: root)

        let fresh = try SiftEngine(directory: root)
        let freshness = try await fresh.ensureFresh()
        let greet = try await SemanticStoreWarmUp.settled { try await fresh.lookup(symbol: "greet()", freshness: freshness) }
        return try (greet, fresh.statusText(freshness: freshness))
    }

    /// A file deleted and then written again is not gone: it is newer than the build, and counted as that and nothing else.
    @Test
    func aDeletedFileWrittenAgainIsNewerRatherThanDeleted() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let caller = root.appendingPathComponent("Sources/Lib/Caller.swift")
        let source = try String(contentsOf: caller, encoding: .utf8)
        try FileManager.default.removeItem(at: caller)
        _ = try await engine.ensureFresh()
        try (source + "\nfunc added() {}\n").write(to: caller, atomically: true, encoding: .utf8)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("semantic: stale (1 file changed since last build)"))
        #expect(!status.contains("deleted since last build"))
    }
}
