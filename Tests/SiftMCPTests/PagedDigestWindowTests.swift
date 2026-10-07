//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A window of a file whose digest is paged is answered with the first page only where that page lists the members the window reaches; past it, the page accounts for none of what the command would print, so the window is answered with the members it overlaps.
@Suite(.temporaryDirectories)
struct PagedDigestWindowTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A trailing comment of 124 bytes, which a digest line never carries, so a window over padded lines weighs well more than the members it overlaps.
    private static let padding = " // " + String(repeating: "x", count: 120)

    /// `struct Big` of 200 padded one-line functions at lines 3-202, then `tail()` at lines 204-235 with a thrice-padded body, a blank line 236, `after()` at 237, and the closing brace at 238 — a digest whose first page lists `f1` to `f59` and is smaller than a window over `tail()`.
    ///
    /// With `documented`, a `///` line sits above `f60` — the first function the page leaves out, which then starts at line 62 and is declared at 63.
    private static func pagedRepository(documented: Bool = false) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        var many = (1 ... 200).map { "    func f\($0)(value: Int) -> Int { value }\(padding)" }
        if documented {
            many[59] = "    /// Sixty.\n" + many[59]
        }
        let body = (1 ... 30).map { "        let v\($0) = \($0)\(padding)\(padding)\(padding)" }
        let source = ["/// Big.", "struct Big {"] + many + ["", "    func tail() -> Int {"] + body + [
            "    }",
            "",
            "    func after() -> Int { 0 }",
            "}",
            "",
        ]
        try source.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Big.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// What `outcome` answered, or a recorded issue where it withheld.
    private static func answered(_ outcome: InPlaceAnswerer.Outcome, sourceLocation: SourceLocation = #_sourceLocation) -> InPlaceAnswerer.Answered? {
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return answered
    }

    /// A window over `tail()` and `after()`, both past the first page, is answered with those two members rather than a page that lists neither.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowPastTheFirstPageIsAnsweredWithItsMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.pagedRepository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 205 ... 237, in: root))

        guard let answered = Self.answered(outcome) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:205-237"])
        #expect(answered.reason.contains("func tail() -> Int  :204-235"))
        #expect(answered.reason.contains("func after() -> Int  :237"))
        #expect(answered.reason.contains("the whole digest's first page stops short of some of them"))
    }

    /// A `tail` of the file reaches only past the first page too, and is answered with the members it overlaps.
    @Test
    func aTailPastTheFirstPageIsAnsweredWithItsMembers() async throws {
        let root = try await Self.pagedRepository()
        let match = try #require(InPlaceShape.match(forShell: "tail -n 34 Sources/App/Big.swift", in: root.path))

        guard let answered = try await Self.answered(Self.outcome(match)) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:205-238"])
        #expect(answered.reason.contains("func after() -> Int  :237"))
    }

    /// Beside another file's window on one shell line, the window past the first page is answered with its members there too.
    ///
    /// `Depot`'s window spans 120 lines so its own members save the floor: a file whose lines the answer does not show is never carried by another part's saving.
    @Test
    func aWindowPastTheFirstPageBesideAnotherFilesWindowIsAnsweredWithItsMembers() async throws {
        let root = try await Self.pagedRepository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '205,237p' Sources/App/Big.swift && sed -n '1,120p' Sources/App/Depot.swift", in: root.path))

        guard let answered = try await Self.answered(Self.outcome(match)) else { return }

        #expect(answered.calls.map(\.target).contains("Sources/App/Big.swift:205-237"))
        #expect(!answered.calls.map(\.target).contains("Sources/App/Big.swift"))
        #expect(answered.reason.contains("func tail() -> Int  :204-235"))
    }

    /// A window the first page does reach is answered with its members all the same, strictly smaller than that page as they are, and the note says so rather than that the page stops short.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowTheFirstPageReachesIsAnsweredWithItsSmallerMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.pagedRepository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 3 ... 50, in: root))

        guard let answered = Self.answered(outcome) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:3-50"])
        #expect(answered.reason.contains("func f48(value: Int) -> Int  :50"))
        #expect(answered.reason.contains(FileDigestParts.larger))
        #expect(!answered.reason.contains(FileDigestParts.unreached))
    }

    /// `f59` is the last function the page lists, at line 61: a window ending there is reached, so the page could stand in, but its members are smaller and answer it.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowEndingOnTheLastListedMemberIsAnsweredWithItsSmallerMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.pagedRepository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 3 ... 61, in: root))

        guard let answered = Self.answered(outcome) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:3-61"])
        #expect(answered.reason.contains(FileDigestParts.larger))
        #expect(!answered.reason.contains(FileDigestParts.unreached))
    }

    /// `f60`, at line 62, is the first function the page leaves out: a window ending on it is not reached, so its members stand in.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowEndingOnTheFirstUnlistedMemberIsAnsweredWithItsMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.pagedRepository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 3 ... 62, in: root))

        guard let answered = Self.answered(outcome) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:3-62"])
        #expect(answered.reason.contains("func f60(value: Int) -> Int  :62"))
        #expect(answered.reason.contains("the whole digest's first page stops short of some of them"))
    }

    /// A window ending on the doc comment above `f60` reads that function's lines, so the page does not reach it and the members stand in.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowEndingOnTheDocCommentOfTheFirstUnlistedMemberIsAnsweredWithItsMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.pagedRepository(documented: true)

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 3 ... 62, in: root))

        guard let answered = Self.answered(outcome) else { return }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:3-62"])
        #expect(answered.reason.contains("func f60(value: Int) -> Int  :63"))
    }
}
