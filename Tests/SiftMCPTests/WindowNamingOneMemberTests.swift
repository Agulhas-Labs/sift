//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A line window whose members answer would name one member and nothing else runs rather than being answered in place, since that one line is what the reader who chose the window already knew: decided on what the answer would print, not on whether the window lies inside the member.
@Suite(.temporaryDirectories)
struct WindowNamingOneMemberTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A trailing comment of 164 bytes, which pads a window's lines past the floor below which a window whose lines its answer does not show runs anyway, yet keeps a window of thirty of them smaller than the first page of the file's digest, so the window is answered with the members it overlaps; no line number moves.
    private static let padding = " // " + String(repeating: "x", count: 160)

    /// `struct Big` of 400 one-line functions, then `tail()` at lines 404-435 with a padded body, a blank line 436, `after()` at 437, and the closing brace at 438 — a digest paged well past the size of any window here.
    private static func bigRepository() async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let many = (1 ... 400).map { "    func f\($0)(value: Int) -> Int { value }" }
        let body = (1 ... 30).map { "        let v\($0) = \($0)\(padding)" }
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

    /// A window over one member and a blank line outside it — after the member, or before it — runs: its answer would name that member beneath its container's header and nothing else, the blank line being one no answer shows.
    @Test(arguments: WindowReadSpelling.allCases, [407 ... 436, 403 ... 433])
    func aWindowReachingPastItsMemberOntoABlankLineRuns(spelling: WindowReadSpelling, lines: ClosedRange<Int>) async throws {
        let root = try await Self.bigRepository()

        #expect(try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: lines, in: root)) == .withheld(.linesNotShown))
    }

    /// A window across two members is still answered, naming both: its answer shows the reader something the window's own member line does not.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowAcrossTwoMembersIsAnswered(spelling: WindowReadSpelling) async throws {
        let root = try await Self.bigRepository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 405 ... 437, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("a window across two members is answered, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Big.swift:405-437"])
        #expect(answered.reason.contains("func tail() -> Int  :404-435"))
        #expect(answered.reason.contains("func after() -> Int  :437"))
    }

    /// A window inside a SwiftUI view's `body` is answered: the member's answer carries an outline of what the body builds, which the window's own member line does not.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowInsideAViewBodyIsAnswered(spelling: WindowReadSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let rows = (1 ... 12).map { "            Text(\"row \($0)\")\(Self.padding)\(Self.padding)\(Self.padding)" }
        // Eighty declarations after the view keep the file's digest well clear of the compression floor.
        let filler = (1 ... 80).map { "func filler\($0)(value: Int) -> Int { value }" }
        let source = ["import SwiftUI", "", "struct Screen: View {", "    var body: some View {", "        VStack {"] + rows + ["        }", "    }", "}", ""] + filler + [""]
        try source.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Screen.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Screen.swift", lines: 6 ... 15, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("a window inside a view body is answered, got \(outcome)")
            return
        }

        #expect(answered.reason.contains("VStack :5"))
    }
}
