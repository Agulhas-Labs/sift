//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole-file `Read` the hook answers is answered with the file's whole digest, never a sixty-member-line page and a cursor.
@Suite(.temporaryDirectories)
struct InterceptedReadWholeDigestTests {
    private static var path: String {
        "Sources/App/Crate.swift"
    }

    /// A repository whose `Crate` has `count` members, each a short signature over a body padded by `padding` bytes, so the digest is a small part of the source.
    private static func repository(members count: Int, padding: Int = 400) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let pad = " //" + String(repeating: "x", count: padding - 3)
        let members = (1 ... count).map { index in
            "    func take\(index)(first: Int) -> Int {\n        let count = \(index)\(pad)\n        return count * 2\n    }"
        }
        try ("/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    private static func answered(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, serverGone: false, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: InPlaceAnswer.sizeBudget, backoff: backoff)
        }
    }

    /// A file of more member lines than a page holds, whose whole digest fits the budget, is answered with every member and no cursor.
    @Test
    func aWholeReadOfMoreThanAPageIsAnsweredWithEveryMember() async throws {
        let root = try await Self.repository(members: 100)
        let outcome = try await Self.answered("cat \(Self.path)", in: root)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the whole digest, got \(outcome)")
            return
        }

        #expect(answered.reason.contains("func take100("))
        #expect(!answered.reason.contains("truncated:"))
        #expect(!answered.reason.contains("pass offset"))
        #expect(answered.reason.utf8.count <= InPlaceAnswer.sizeBudget)
    }

    /// A whole digest past the size budget but within two fifths of the file is still answered whole, every member and no cursor.
    @Test
    func aWholeDigestPastTheBudgetWithinTheShareIsAnsweredWhole() async throws {
        let root = try await Self.repository(members: 260)
        let outcome = try await Self.answered("cat \(Self.path)", in: root)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected the whole digest, got \(outcome)")
            return
        }

        #expect(answered.reason.utf8.count > InPlaceAnswer.sizeBudget)
        #expect(answered.reason.contains("func take260("))
        #expect(!answered.reason.contains("pass offset"))
    }

    /// A whole digest past the budget and past two fifths of the file is cut to a page and a cursor, as before.
    @Test
    func aWholeDigestPastTheShareIsStillCut() async throws {
        let root = try await Self.repository(members: 260, padding: 3)
        let outcome = try await Self.answered("cat \(Self.path)", in: root)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected a cut page, got \(outcome)")
            return
        }

        #expect(answered.reason.utf8.count <= InPlaceAnswer.sizeBudget)
        #expect(answered.reason.contains("pass offset"))
        #expect(!answered.reason.contains("func take260("))
    }

    /// A file whose whole digest saves less than the floor against its source is not answered with a smaller page of it: the read runs.
    @Test
    func aWholeReadWhoseDigestSavesTooLittleRuns() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 100).map { "    func take\($0)(first: Int) -> Int { \($0) }" }
        try ("struct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent(Self.path), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let outcome = try await Self.answered("cat \(Self.path)", in: root)

        guard case let .withheld(reason) = outcome else {
            Issue.record("expected the read to run, got \(outcome)")
            return
        }

        #expect(reason == .notSmaller)
    }

    /// The explicit digest keeps its page and its cursor.
    @Test
    func theExplicitDigestStillPages() async throws {
        let root = try await Self.repository(members: 100)
        let engine = try SiftEngine(directory: root)
        let digest = try #require(try ExactAnswer.fileDigest(in: engine, path: Self.path))

        #expect(digest.text.contains("truncated:"))
    }
}
