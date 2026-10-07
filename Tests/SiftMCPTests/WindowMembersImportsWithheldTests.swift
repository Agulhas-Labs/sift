//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A window over a file's imports is never answered with members that leave the `import` lines it prints without a trace: where the whole digest, whose `imports:` line accounts for them, is not served — its saving below the floor, a first page stopping short of the window, or a nested type's members named on its line alone — the read runs.
@Suite(.temporaryDirectories)
struct WindowMembersImportsWithheldTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// A trailing comment of 50 bytes, which a digest line never carries, so a window over padded lines weighs well more than the members it overlaps.
    private static let padding = " // " + String(repeating: "x", count: 50)

    /// `import Mod1` to `import Mod40` on lines 1-40, a blank line, a doc comment, then `struct Thing` over lines 43-119 with `step1()` to `step5()`, fifteen short lines each from line 44 — so a window of lines 1-60 weighs more than the whole digest by less than the floor, and its members answer, naming `step1()` and `step2()` alone, far less.
    private static var thing: [String] {
        var lines = (1 ... 40).map { "import Mod\($0)" } + ["", "/// A thing.", "struct Thing {"]
        for step in 1 ... 5 {
            lines.append("    func step\(step)() -> Int {")
            lines += (1 ... 13).map { "        let value\($0) = \($0) // padding this line out a little further, and more" }
            lines.append("    }")
        }
        return lines + ["}", ""]
    }

    /// `import Foundation` and `import Mod2` on lines 1-2, then `struct Big` of 200 padded one-line functions at lines 6-205 — a digest whose first page stops short of `f70` at line 75.
    private static var big: [String] {
        ["import Foundation", "import Mod2", "", "/// Big.", "struct Big {"] + (1 ... 200).map { "    func f\($0)(value: Int) -> Int { value }\(padding)" } + ["}", ""]
    }

    /// `import Foundation` and `import Mod2` on lines 1-2, then `struct Outer`: `a()` at line 6, `struct Inner` over lines 7-108 holding `n1()` to `n10()` — ten lines each, `n1()` at 8-17 and `n2()` at 18-27 — whose members the file's digest names on `Inner`'s line alone.
    private static var outer: [String] {
        var lines = ["import Foundation", "import Mod2", "", "/// Outer.", "struct Outer {", "    func a() -> Int { 0 }", "    struct Inner {"]
        for index in 1 ... 10 {
            let statements = (1 ... 8).map { "            let v\($0) = \($0)\(padding)\(padding)" }
            lines += ["        func n\(index)() -> Int {"] + statements + ["        }"]
        }
        return lines + ["    }", "    func b() -> Int { 1 }", "}", ""]
    }

    /// A repository holding `lines` at `Sources/App/<name>.swift`, indexed.
    private static func repository(_ name: String, _ lines: [String]) async throws -> URL {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A window over the imports whose whole digest saves less than the floor runs, rather than being answered with the two members it overlaps.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOverTheImportsBelowTheFloorRuns(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository("Thing", Self.thing)

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Thing.swift", lines: 1 ... 60, in: root))

        #expect(outcome == .withheld(.linesNotShown))
    }

    /// Beside another file's window on one shell line, the window over the imports below the floor keeps the line from being answered with members.
    ///
    /// `Depot`'s window spans 120 lines so its own members save the floor, leaving the imports window the one thing that makes the line run.
    @Test
    func aWindowOverTheImportsBelowTheFloorBesideAnotherFilesWindowRuns() async throws {
        let root = try await Self.repository("Thing", Self.thing)
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,60p' Sources/App/Thing.swift && sed -n '1,120p' Sources/App/Depot.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        #expect(outcome == .withheld(.linesNotShown))
    }

    /// A window over the imports past the digest's first page runs, rather than being answered with the functions it overlaps.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOverTheImportsPastTheFirstPageRuns(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository("Big", Self.big)

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Big.swift", lines: 1 ... 75, in: root))

        #expect(outcome == .withheld(.notExact))
    }

    /// A window over the imports and a nested type's members the digest names without their lines runs, rather than being answered with those members.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOverTheImportsAndUnplacedMembersRuns(spelling: WindowReadSpelling) async throws {
        let root = try await Self.repository("Outer", Self.outer)

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Outer.swift", lines: 1 ... 27, in: root))

        #expect(outcome == .withheld(.notExact))
    }

    /// Beside another file's window on one shell line, the window over the imports and unplaced members keeps the line from being answered with them.
    @Test
    func aWindowOverTheImportsAndUnplacedMembersBesideAnotherFilesWindowRuns() async throws {
        let root = try await Self.repository("Outer", Self.outer)
        let match = try #require(InPlaceShape.match(forShell: "sed -n '1,27p' Sources/App/Outer.swift && sed -n '1,40p' Sources/App/Depot.swift", in: root.path))

        let outcome = try await Self.outcome(match)

        #expect(outcome == .withheld(.notExact))
    }
}
