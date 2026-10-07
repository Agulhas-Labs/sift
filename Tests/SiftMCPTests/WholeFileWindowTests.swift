//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A window that prints every line of a Swift file is the whole read of it, and gets the answer a whole read gets, however the window is written.
@Suite(.temporaryDirectories)
struct WholeFileWindowTests {
    /// The file every case reads, in the shared fixture repository.
    private static var path: String {
        "Sources/App/Depot.swift"
    }

    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// The answer `outcome` holds, or a recorded issue.
    private static func answered(_ outcome: InPlaceAnswerer.Outcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> InPlaceAnswerer.Answered {
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return answered
    }

    /// The number of lines the file holds in `root`.
    private static func lineCount(in root: URL) throws -> Int {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count - 1
    }

    /// Each spelling of a window over every line is answered as the whole read of its kind is: the digest of the whole file, in the same words.
    @Test(arguments: WholeFileSpelling.allCases)
    func aWindowOverEveryLineIsTheWholeRead(spelling: WholeFileSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let whole = try await Self.answered(Self.outcome(spelling.wholeMatch(path: Self.path, in: root)))

        let window = try await Self.answered(Self.outcome(spelling.match(path: Self.path, lines: Self.lineCount(in: root), in: root)))

        #expect(window.calls.map(\.target) == [Self.path])
        #expect(window.reason == whole.reason)
    }

    /// A window that stops a line short of the file's end is no whole read, and is not answered with the file's whole digest.
    @Test(arguments: [WholeFileSpelling.readFromLineOne, .shellSed, .shellHead])
    func aWindowMissingTheLastLineIsNotTheWholeRead(spelling: WholeFileSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let lines = try Self.lineCount(in: root) - 1

        let outcome = try await Self.outcome(spelling.match(path: Self.path, lines: lines, in: root))

        if case let .answered(answered) = outcome {
            #expect(!answered.calls.map(\.target).contains(Self.path), "a window of \(lines) lines is not the file's whole digest")
        }
    }

    /// A window that starts on the second line is no whole read, and is not answered with the file's whole digest.
    @Test
    func aWindowFromTheSecondLineIsNotTheWholeRead() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let match = try #require(InPlaceShape.match(forRead: Self.path, in: root.path, window: LineWindow(offset: 2, limit: 2000)))

        let outcome = try await Self.outcome(match)

        if case let .answered(answered) = outcome {
            #expect(!answered.calls.map(\.target).contains(Self.path), "a window from line 2 is not the file's whole digest")
        }
    }
}
