//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A window whose members answer is strictly smaller than the whole file's digest is answered with those members, even where that digest fits the budget and is smaller than the window: the digest answers a question about the file, the members the one the window asked.
@Suite(.temporaryDirectories)
struct WindowMembersPreferredTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A trailing comment of 104 bytes, which a digest line never carries, so a window over padded lines weighs well more than any listing of the members it overlaps.
    private static let padding = " // " + String(repeating: "x", count: 100)

    /// Lines of padded statements, `count` of them, indented for a function body.
    private static func body(_ count: Int) -> [String] {
        (1 ... count).map { "        let v\($0) = \($0)\(padding)\(padding)" }
    }

    /// `struct Walk`: `m1()` to `m20()` on lines 3-22, `perform()` over lines 23-64, a blank line 65, `prepare()` over lines 66-77, `m21()` at 78, and the closing brace at 79 — a file whose whole digest is far smaller than a window over the two long functions, and far larger than the two lines naming them.
    private static var walk: [String] {
        var lines = ["/// Walk.", "struct Walk {"]
        lines += (1 ... 20).map { "    func m\($0)() -> Int { \($0) }" }
        lines += ["    func perform() -> Int {"] + body(40) + ["    }", ""]
        lines += ["    func prepare() -> Int {"] + body(10) + ["    }"]
        return lines + ["    func m21() -> Int { 21 }", "}", ""]
    }

    /// A repository holding `Walk` at `Sources/App/Walk.swift`, indexed.
    private static func repository() async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try walk.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Walk.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A window running from inside one long function into the next is answered with those two functions, not the whole file's digest — smaller than the window as that digest is, the members are smaller still.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowSpillingFromOneMemberIntoTheNextIsAnsweredWithThoseMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Walk.swift", lines: 40 ... 70, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Walk.swift:40-70"])
        #expect(answered.reason.contains("func perform() -> Int  :23-64"))
        #expect(answered.reason.contains("func prepare() -> Int  :66-77"))
        #expect(answered.reason.contains("the whole digest is larger than they are"))
        #expect(!answered.reason.contains("func m1() -> Int"))
    }

    /// Beside another file's whole read on one shell line, the same window is answered with its two functions too, the line weighed as one against the digests it would otherwise serve.
    @Test
    func aWindowBesideAnotherFilesWholeReadIsAnsweredWithItsMembers() async throws {
        let root = try await Self.repository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '40,70p' Sources/App/Walk.swift && cat Sources/App/Depot.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Walk.swift:40-70", "Sources/App/Depot.swift"])
        #expect(answered.reason.contains("only members of Sources/App/Walk.swift lines 40-70 are shown; the whole digest is larger than they are"))
        #expect(answered.reason.contains("func prepare() -> Int  :66-77"))
        #expect(!answered.reason.contains("func m1() -> Int"))
    }

    /// A whole read of the same file is still answered with the whole file's digest: the members answer is for a window alone.
    @Test
    func aWholeReadKeepsTheWholeDigest() async throws {
        let root = try await Self.repository()
        let match = try #require(InPlaceShape.match(forShell: "cat Sources/App/Walk.swift", in: root.path))

        guard case let .answered(answered) = try await Self.outcome(match) else {
            Issue.record("expected an answer")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Walk.swift"])
        #expect(answered.reason.contains("func m1() -> Int"))
    }
}
