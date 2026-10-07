//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The whole file's digest stands in for a window only where it gives every member the window overlaps a line of its own, with its line range: a nested type's members, which it names on their type's line alone, it places nowhere, so a window over them is answered with those members or runs.
@Suite(.temporaryDirectories)
struct WindowMembersPlacedTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A trailing comment of 354 bytes, which a digest line never carries, so a window over padded lines weighs well more than any listing of the members it overlaps, and saves the floor over a single member's eight statements.
    private static let padding = " // " + String(repeating: "x", count: 350)

    /// `struct Outer`: `a()` at line 3, `struct Inner` over lines 4-105 holding `n1()` to `n10()` — ten lines each, `n1()` at 5-14, `n9()` at 85-94 and `n10()` at 95-104 — then `b()` at 106 and the closing brace at 107.
    ///
    /// The file's digest collapses `Inner` to its members' names, so it states no line of any of them, and is far smaller than a window over two of them.
    static var outer: [String] {
        var lines = ["/// Outer.", "struct Outer {", "    func a() -> Int { 0 }", "    struct Inner {"]
        for index in 1 ... 10 {
            let statements = (1 ... 8).map { "            let v\($0) = \($0)\(padding)\(padding)" }
            lines += ["        func n\(index)() -> Int {"] + statements + ["        }"]
        }
        return lines + ["    }", "    func b() -> Int { 1 }", "}", ""]
    }

    /// A repository holding `Outer` at `Sources/App/Outer.swift`, indexed.
    private static func repository() async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        try outer.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Outer.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// Every declaration of `Outer.swift` whose lines overlap `lines`, apart from the ones enclosing the whole window: a member the command would print some line of.
    private static func overlapping(_ lines: ClosedRange<Int>, in root: URL) throws -> [SymbolRow] {
        try SiftEngine(directory: root).store.symbols(inFile: "Sources/App/Outer.swift").filter { row in
            row.line <= lines.upperBound && lines.lowerBound <= row.endLine && !(row.line < lines.lowerBound && lines.upperBound < row.endLine)
        }
    }

    /// A window over two of a nested type's members is answered with those members, each beside its lines, rather than with the whole digest that names them without any.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOverANestedTypesMembersIsAnsweredWithThoseMembers(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Outer.swift", lines: 85 ... 104, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Sources/App/Outer.swift:85-104"])
        #expect(answered.reason.contains("func n9() -> Int  :85-94"))
        #expect(answered.reason.contains("func n10() -> Int  :95-104"))
        #expect(answered.reason.contains("the whole digest names some of them without their lines"))
    }

    /// Whatever answers a window names every member its lines overlap beside that member's own lines, so it accounts for everything the command would have printed there.
    @Test(arguments: [85 ... 104, 3 ... 20, 60 ... 90])
    func aWindowsAnswerNamesEveryMemberItOverlapsWithItsLines(lines: ClosedRange<Int>) async throws {
        let root = try await Self.repository()
        let members = try Self.overlapping(lines, in: root)

        let outcome = try await Self.outcome(WindowReadSpelling.shell.match(path: "Sources/App/Outer.swift", lines: lines, in: root))

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(!members.isEmpty)
        for member in members {
            let listed = answered.reason.components(separatedBy: "\n").contains { $0.contains(member.baseName) && $0.hasSuffix("  \(member.rangeDescription)") }
            #expect(listed, "\(member.baseName) \(member.rangeDescription) is not listed with its lines")
        }
    }

    /// Beside another file's window on one shell line, the window over the nested type's members is answered with them too.
    ///
    /// `Depot`'s window spans 120 lines so its own members save the floor: a file whose lines the answer does not show is never carried by another part's saving.
    @Test
    func aWindowOverANestedTypesMembersBesideAnotherFilesWindowIsAnsweredWithThoseMembers() async throws {
        let root = try await Self.repository()
        let match = try #require(InPlaceShape.match(forShell: "sed -n '85,104p' Sources/App/Outer.swift && sed -n '1,120p' Sources/App/Depot.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target).first == "Sources/App/Outer.swift:85-104")
        #expect(answered.reason.contains("func n10() -> Int  :95-104"))
        #expect(answered.reason.contains("the whole digest names some of them without their lines"))
    }
}
