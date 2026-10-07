//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Several whole reads in one command, answered together under one header or not at all.
@Suite(.temporaryDirectories)
struct InPlaceReadsTests {
    /// What the shell matcher reads `command` as, run from `/repo`.
    private static func match(_ command: String) -> InPlaceShape.Match? {
        InPlaceShape.match(forShell: command, in: "/repo")
    }

    /// ``InPlaceAnswerer/answer(_:serverGone:timeBudget:sizeBudget:backoff:)`` for what `command` matches in `root`, on a thread of its own as the hook runs it.
    private static func outcome(
        _ command: String,
        in root: URL,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: sizeBudget, backoff: backoff)
        }
    }

    /// Every lookup of a command being a whole read, the reads are one match, in command order; a literal `echo` label between them is printed where it falls, so the match is the whole command.
    @Test
    func severalWholeReadsAreOneMatch() throws {
        let labelled = try #require(Self.match("cat Sources/App/Depot.swift && echo --- && cat Sources/App/Alpha.swift"))

        #expect(labelled.calls == [.fileDigest(path: "Sources/App/Depot.swift"), .fileDigest(path: "Sources/App/Alpha.swift")])
        #expect(labelled.isWholeCommand == true)
        #expect(labelled.literals == [1: "---\n"])
        #expect(Self.match("cat Sources/App/Depot.swift; cat -n Sources/App/Alpha.swift")?.isWholeCommand == true)
        // A document beside a Swift read is one more read of the lot.
        #expect(Self.match("cat Docs/Plan.md && cat Sources/App/Alpha.swift")?.calls
            == [.documentOutline(path: "Docs/Plan.md"), .fileDigest(path: "Sources/App/Alpha.swift")])
    }

    /// A file read twice, a move between the reads, or documents alone are no shared answer.
    @Test(arguments: [
        "cat Sources/App/Depot.swift && cat Sources/App/Depot.swift",
        "cat Sources/App/Depot.swift && cat Sources/App/../App/Depot.swift",
        "cat Sources/App/Depot.swift && cd Sources && cat App/Alpha.swift",
        "cat Docs/Plan.md && cat Docs/Design.md",
    ])
    func readsThatCannotShareAnAnswerAreNoMatch(command: String) {
        #expect(Self.match(command) == nil)
    }

    /// Beside any other lookup a document's `cat` rides as it did before reads were answered together.
    @Test
    func aDocumentBesideAnotherLookupRides() {
        let match = Self.match("cat Docs/Plan.md && grep -n 'func go' Sources/App/Alpha.swift")

        #expect(match?.calls.count == 1)
        #expect(match?.isWholeCommand == false)
    }

    /// Each read's answer comes under one freshness header, in command order, named in the opening line as the whole command with its `---` label printed between them, and every byte is charged to one call.
    @Test
    func severalReadsAreAnsweredUnderOneHeader() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let outcome = try await Self.outcome("cat Sources/App/Depot.swift && echo --- && cat Sources/App/Alpha.swift", in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        let lines = answered.reason.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0].hasPrefix("sift answered this with `digest Sources/App/Depot.swift`, `digest Sources/App/Alpha.swift`"))
        #expect(lines.filter { $0.hasPrefix("tree: ") }.count == 1)
        let depot = try #require(lines.firstIndex { $0.hasPrefix("Sources/App/Depot.swift — module: ") })
        // The second part opens on its header, marked as the start of a part, the guessed-module banner said once above both.
        let alpha = try #require(lines.firstIndex { $0.hasPrefix("\(SourcePassthrough.partMarker)Sources/App/Alpha.swift — module: ") })
        let label = try #require(lines.firstIndex { $0.hasSuffix("---") })
        #expect(depot < label)
        #expect(label < alpha)
        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift", "Sources/App/Alpha.swift"])
        #expect(answered.calls.reduce(0) { $0 + $1.bytes.served } == answered.reason.utf8.count)
        #expect(answered.reason.utf8.count <= InPlaceAnswer.sizeBudget)
    }

    /// A document read beside a Swift read sits under the one header as it stands, its own first line saying it was read live.
    @Test
    func aDocumentIsAnsweredBesideASwiftRead() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        _ = try InPlaceAnswerTests.document(in: root)
        let outcome = try await Self.outcome("cat Sources/App/Depot.swift && cat Docs/Plan.md", in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        #expect(answered.calls.map(\.target) == ["Sources/App/Depot.swift", "Docs/Plan.md"])
        #expect(answered.reason.components(separatedBy: "\ntree: ").count == 2)
        let digest = try #require(answered.reason.range(of: "Sources/App/Depot.swift — module: "))
        let outline = try #require(answered.reason.range(of: "Budgets"))
        #expect(digest.lowerBound < outline.lowerBound)
    }

    /// Reads in two repositories are withheld: one header cannot speak for two trees.
    @Test
    func readsInTwoRepositoriesAreWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let other = try await InPlaceAnswerTests.indexedRepository()
        let command = "cat Sources/App/Depot.swift && cat \(other.path)/Sources/App/Depot.swift"

        #expect(try await Self.outcome(command, in: root) == .withheld(.outsideRoot))
    }

    /// One read that cannot be answered withholds the lot, so a partial answer is never read as complete.
    @Test
    func oneUnanswerableReadWithholdsEveryRead() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        #expect(try await Self.outcome("cat Sources/App/Depot.swift && cat Sources/App/Missing.swift", in: root) == .withheld(.notExact))
    }

    /// The size budget bounds the whole refusal, every read included.
    @Test
    func theSizeBudgetBoundsEveryReadTogether() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let command = "cat Sources/App/Depot.swift && cat Sources/App/Alpha.swift"

        #expect(try await Self.outcome(command, in: root, sizeBudget: 400) == .withheld(.overSize))
    }

    /// A digest long enough to page ends with the cursor spelled for the face the opening line names its calls in, alone or beside another read.
    @Test(arguments: [false, true])
    func aPagedDigestSpellsItsCursorForTheFaceThatAsked(serverGone: Bool) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 70).map { "    func take\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        try ("/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Crate.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let backoff = try InPlaceAnswerTests.backoff()
        let cursor = serverGone ? "pass --offset 60" : "pass offset: 60"

        for command in ["cat Sources/App/Crate.swift", "cat Sources/App/Crate.swift && cat Sources/App/Alpha.swift"] {
            let match = try #require(InPlaceShape.match(forShell: command, in: root.path))
            let outcome = await InPlaceAnswerTests.onItsOwnThread {
                InPlaceAnswerer.answer(match, serverGone: serverGone, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: InPlaceAnswer.sizeBudget, backoff: backoff)
            }
            guard case let .answered(answered) = outcome else {
                Issue.record("expected an answer to \(command), got \(outcome)")
                continue
            }
            #expect(answered.reason.contains("more member lines — \(cursor)"), "\(command)")
        }
    }
}
