//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A member grep whose context count reaches past the member it matched: the member's source, and the lines past it served beside it as they stand.
@Suite(.temporaryDirectories)
struct MemberGrepContextTests {
    /// Context lines inside a source served are served there, and the lines a context's count reaches past a member's end are served beside it verbatim, numbered as grep numbers them — a whole following member's lines as lines, never as that member.
    @Test
    func contextPastAMemberIsServedVerbatimBesideIt() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()

        let inside = try #require(try await InPlaceAnswerTests.answered("grep -n -A 2 'func saves' Sources/App/Store.swift", in: root))
        let past = try #require(try await InPlaceAnswerTests.answered("grep -n -A 4 'func saves' Sources/App/Store.swift", in: root))
        let whole = try #require(try await InPlaceAnswerTests.answered("grep -n -A 10 'func saves' Sources/App/Store.swift", in: root))

        #expect(inside.calls.map(\.target) == ["Store.saves()"])
        #expect(!inside.reason.contains("the rest of the lines"))
        #expect(past.calls.map(\.target) == ["Store.saves()"])
        #expect(past.reason.contains("        for item in items { _ = item.lowercased() }\n    }\n\nSources/App/Store.swift:16-17, the rest of the lines the context asked for:\n16-    func classify(_ value: Int) -> String {\n17-        switch value {\n"))
        #expect(whole.calls.map(\.target) == ["Store.saves()"])
        #expect(whole.reason.contains("Sources/App/Store.swift:16-23, the rest of the lines the context asked for:\n16-    func classify(_ value: Int) -> String {\n"))
        #expect(whole.reason.contains("\n23-        func save() {}\n"))
        #expect(past.calls.reduce(0) { $0 + $1.bytes.served } == past.reason.utf8.count)
    }

    /// Lines a `-B` count reaches before a member's start come ahead of it, and each member's overrun follows that member, charged to it.
    @Test
    func contextBeforeAMemberAndAfterEachComesInLineOrder() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()

        let before = try #require(try await InPlaceAnswerTests.answered("grep -n -B 2 'func saves' Sources/App/Store.swift", in: root))
        let both = try #require(try await InPlaceAnswerTests.answered("grep -n -A 3 'var body' Sources/App/Screens.swift", in: root))

        let leading = try #require(before.reason.range(of: "Sources/App/Store.swift:11-12, the rest of the lines the context asked for:\n11-        _ = (now, message)\n12-    }\n\n"))
        let member = try #require(before.reason.range(of: "    public func saves() {"))
        #expect(leading.upperBound <= member.lowerBound)
        #expect(both.calls.map(\.target) == ["Screen.body", "Row.body"])
        let first = try #require(both.reason.range(of: "Sources/App/Screens.swift:5, the rest of the lines the context asked for:\n5-}\n\n"))
        let second = try #require(both.reason.range(of: "        2\n"))
        #expect(first.upperBound <= second.lowerBound)
        #expect(both.reason.contains("Sources/App/Screens.swift:11, the rest of the lines the context asked for:\n11-}"))
        #expect(both.calls.reduce(0) { $0 + $1.bytes.served } == both.reason.utf8.count)
    }

    /// Context past a member earns nothing wider: a match inside a body still refuses, and an answer the overrun carries over the size budget is withheld as any other is.
    @Test
    func contextPastAMemberStillRefusesAMatchInABodyAndTheSizeBudget() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()
        let command = "grep -n -A 10 'func saves' Sources/App/Store.swift"
        let answered = try #require(try await InPlaceAnswerTests.answered(command, in: root))
        let shaped = try #require(InPlaceShape.match(forShell: command, in: root.path))

        #expect(try await InPlaceAnswerTests.outcome("grep -n -A 3 'func save' Sources/App/Store.swift", in: root) == .withheld(.notExact))
        #expect(try await InPlaceAnswerTests.outcome("grep -n -A 2 'let now' Sources/App/Store.swift", in: root) == .withheld(.notExact))
        #expect(try await InPlaceAnswerTests.answer(shaped.call, from: shaped.directory, sizeBudget: answered.reason.utf8.count - 1) == .withheld(.overSize))
    }

    /// A `head` cut applied after the context is computed can bring what actually prints back inside the member, even where the `-A` count alone reaches past its end: the cut decides what is printed, so there is nothing left over to serve as a run past it.
    @Test
    func contextPastAMemberButCutBackInsideByHeadCarriesNoOverrun() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()

        let answered = try #require(try await InPlaceAnswerTests.answered(
            "grep -n 'func saves' -A 10 Sources/App/Store.swift | head -3", in: root
        ))

        #expect(answered.calls.map(\.target) == ["Store.saves()"])
        #expect(!answered.reason.contains("the rest of the lines"))
        #expect(answered.reason.contains("    public func saves() {"))
    }

    /// A `tail` cut that drops the matched line itself — keeping only lines the context printed past it — leaves nothing a member's declaration was matched on, so the answer is withheld rather than guessed at from context alone.
    @Test
    func contextPastAMemberCutToDropTheMatchLineIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.reviewedRepository()

        #expect(try await InPlaceAnswerTests.outcome(
            "grep -n 'func saves' -A 10 Sources/App/Store.swift | tail -3", in: root
        ) == .withheld(.notExact))
    }
}
