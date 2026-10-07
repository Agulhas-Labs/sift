//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A line window whose answer would not show the lines it asks for runs rather than being answered in place, since the identical re-run would follow it: a window of a declaration's leading doc comment always, and any window whose answer saves less than the floor.
@Suite(.temporaryDirectories)
struct WindowDocCommentReadTests {
    /// The outcome for `match`, on a thread of its own as the hook runs it.
    private static func outcome(_ match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// Pads every one of `lines` (1-based) in the file at `path` with a trailing comment of `width` bytes, moving no line number.
    private static func widen(linesInFile path: URL, at lines: ClosedRange<Int>, by width: Int) throws {
        var rows = try String(contentsOf: path, encoding: .utf8).components(separatedBy: "\n")
        for line in lines where rows.indices.contains(line - 1) {
            rows[line - 1] += " // " + String(repeating: "x", count: width)
        }
        try rows.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    /// A window of the six doc-comment lines above a function runs as `linesNotShown`, however much its answer would save; the same window taking in the function above and the declaration's own line as well is still answered, so the saving clears the floor and the doc comment alone is what lets it run.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOfADeclarationsLeadingDocCommentRuns(spelling: WindowReadSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let prose = String(repeating: "the spawned child keeps writing until its pipe closes and ", count: 20)
        let doc = (1 ... 6).map { "    /// Paragraph \($0): \(prose)" }
        let source = ["/// Spawns things.", "struct Spawner {", "    func first() -> Int { 1 }", ""] + doc + [
            "    func spawn() -> Int {",
            "        let child = 1",
            "        return child",
            "    }",
            "}",
            "",
        ]
        try source.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Spawner.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let docOnly = try await Self.outcome(spelling.match(path: "Sources/App/Spawner.swift", lines: 5 ... 10, in: root))
        let withDeclaration = try await Self.outcome(spelling.match(path: "Sources/App/Spawner.swift", lines: 3 ... 11, in: root))

        #expect(docOnly == .withheld(.linesNotShown))
        guard case .answered = withDeclaration else {
            Issue.record("the window taking in the declaration is answered, got \(withDeclaration)")
            return
        }
    }

    /// A window of the doc comment above a container that has members runs too: none of its members overlaps those lines, so its answer would name no member, and the doc comment is all that lets it run; the same window taking in the container's own line is answered.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOfAContainersLeadingDocCommentRuns(spelling: WindowReadSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let prose = String(repeating: "the spawned child keeps writing until its pipe closes and ", count: 20)
        let doc = (1 ... 6).map { "/// Paragraph \($0): \(prose)" }
        let source = ["struct First {", "    func one() -> Int { 1 }", "}", ""] + doc + [
            "struct Spawner {",
            "    func spawn() -> Int { 1 }",
            "    func other() -> Int { 2 }",
            "}",
            "",
        ]
        try source.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Spawner.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let docOnly = try await Self.outcome(spelling.match(path: "Sources/App/Spawner.swift", lines: 5 ... 10, in: root))
        let withDeclaration = try await Self.outcome(spelling.match(path: "Sources/App/Spawner.swift", lines: 5 ... 11, in: root))

        #expect(docOnly == .withheld(.linesNotShown))
        guard case .answered = withDeclaration else {
            Issue.record("the window taking in the container's line is answered, got \(withDeclaration)")
            return
        }
    }

    /// A window whose members answer saves under a kilobyte, and shows none of its lines, runs as `linesNotShown`; the same window wide enough to save more than the floor is answered.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowSavingUnderTheFloorWithoutItsLinesRuns(spelling: WindowReadSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try Self.widen(linesInFile: file, at: 50 ... 55, by: 200)
        try await SiftEngine(directory: root).ensureFresh()

        let narrow = try await Self.outcome(spelling.match(path: "Sources/App/Depot.swift", lines: 50 ... 55, in: root))
        try Self.widen(linesInFile: file, at: 50 ... 55, by: 900)
        try await SiftEngine(directory: root).ensureFresh()
        let wide = try await Self.outcome(spelling.match(path: "Sources/App/Depot.swift", lines: 50 ... 55, in: root))

        #expect(narrow == .withheld(.linesNotShown))
        guard case .answered = wide else {
            Issue.record("a window saving over the floor is answered, got \(wide)")
            return
        }
    }

    /// A window of nothing but closing braces, which any answer contains, shows nothing, so it is held to the floor.
    @Test
    func aWindowOfBracesAloneIsNotShown() {
        #expect(!InPlaceAnswer.answer("func first() {\n}\n}\n", showsRunOf: ["}", "}"]))
        #expect(!InPlaceAnswer.answer("func first() {\n}\n}\n", showsRunOf: []))
    }

    /// Lines the answer holds, but out of order or with another line between them, are not shown, so the window is held to the floor.
    @Test
    func linesOutOfOrderOrNotConsecutiveAreNotShown() {
        let window = ["let alpha = 1", "return alpha"]

        #expect(!InPlaceAnswer.answer("return alpha\nlet alpha = 1\n", showsRunOf: window))
        #expect(!InPlaceAnswer.answer("let alpha = 1\nlet beta = 2\nreturn alpha\n", showsRunOf: window))
    }

    /// A window whose lines are in the answer in order, one after another, is shown, whatever punctuation-only lines the answer or the window has between them.
    @Test
    func linesInTheAnswerInOrderAreShown() {
        let window = ["func first() {", "let alpha = 1", "}", "return alpha"]

        #expect(InPlaceAnswer.answer("intro\n    func first() {\n        let alpha = 1\n    return alpha\nouter\n", showsRunOf: window))
        #expect(InPlaceAnswer.answer("func first() {\nlet alpha = 1\n}\n\nreturn alpha\n", showsRunOf: window))
    }

    /// A compound line of two windows, whose answer shows each window's lines in a part of its own, is judged shown per window, so it is answered rather than withheld for lines not shown.
    @Test
    func twoWindowsEachShownInItsOwnPartAreAnswered() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        for name in ["Spawner", "Runner"] {
            let source = ["/// Holds things.", "struct \(name) {", "    var \(name.lowercased())Count: Int", String(repeating: " ", count: 700), "    var \(name.lowercased())Label: String", "    var \(name.lowercased())Flag: Bool", "}", ""]
            try source.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }
        try await SiftEngine(directory: root).ensureFresh()
        let command = "sed -n '3,6p' Sources/App/Spawner.swift; sed -n '3,6p' Sources/App/Runner.swift"
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))

        let outcome = try await Self.outcome(match)

        guard case .answered = outcome else {
            Issue.record("two windows each shown in its own part are answered, got \(outcome)")
            return
        }
    }

    /// A window of two closing braces, in an answer that holds a brace in a doc comment it shows, and saving under the floor, runs as one whose lines the answer does not show does.
    @Test(arguments: WindowReadSpelling.allCases)
    func aWindowOfBracesSavingUnderTheFloorRuns(spelling: WindowReadSpelling) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        var rows = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        rows.insert(contentsOf: ["    /// Counts the {stock} held.", "    func stock41() -> Int {", "        return 41", "    }"], at: 202)
        for line in 206 ... 207 {
            rows[line - 1] += String(repeating: " ", count: 600)
        }
        try rows.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let outcome = try await Self.outcome(spelling.match(path: "Sources/App/Depot.swift", lines: 206 ... 207, in: root))

        #expect(outcome == .withheld(.linesNotShown))
    }

    /// The hook logs the let-through under its own reason, and the audit reads it back as a lookup not worth answering under a rule of its own rather than as a miss.
    @Test
    func theLetThroughIsLoggedAsNotWorthUnderItsOwnRule() throws {
        let directory = try TemporaryDirectory.make("doc-comment-read")
        let log = directory.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: InPlaceAnswerer.Withholding.linesNotShown.rawValue, directory: directory.path, rule: "answerWithheld", call: "w1")

        #expect(SuppressionLog.callsLetThrough(in: log) == ["w1": .linesNotShown])
        var causes = WithholdOnWorthCauses()
        causes[.linesNotShown] += 1
        #expect(causes.total == 1)
    }
}
