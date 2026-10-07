//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The `PostToolUse` hook keeps to its one budget however many files an edit touches, as a Codex `apply_patch` of many files does.
@Suite(.temporaryDirectories)
struct PostToolUseBudgetTests {
    /// How many Swift files the patch under test edits: enough that a pass per file over them costs several budgets.
    static let fileCount = 300

    /// The budget the hook is given, short so the patch cannot be checked whole inside it.
    static let budget: TimeInterval = 0.2

    /// An edit of many indexed files in one directory, every one of which parses, returns within its budget and a margin: the nudge brings the index up to date once for them all, not once for each.
    @Test func anEditOfManyFilesReturnsWithinItsBudget() async throws {
        let repo = try MCPTestRepo.make(declaring: "Depot")
        let names = (0 ..< Self.fileCount).map { "Sources/App/Shelf\($0).swift" }
        try MCPTestRepo.add(Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, "struct Shelf\(index) {\n    func count() -> Int {\n        \(index)\n    }\n}\n")
        }), to: repo)
        try await SiftEngine(directory: repo, registry: nil).ensureFresh()
        let marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("nudge-marks"))
        let cwd = repo.path
        let recorded = RecordedOutput()

        let elapsed = await InPlaceAnswerTests.onItsOwnThread {
            let payloads: [[String: Any]] = names.map { name in
                ["tool_name": "Edit", "tool_input": ["file_path": cwd + "/" + name], "session_id": "s1", "cwd": cwd]
            }
            let started = Date()
            PostToolUseCommand.answer(toEach: payloads, output: recorded.output, marks: marks, timeBudget: Self.budget)
            return Date().timeIntervalSince(started)
        }

        #expect(recorded.printed.isEmpty, "\(recorded.printed)")
        #expect(elapsed < Self.budget + 0.5, "\(Self.fileCount) files took \(elapsed) s against a \(Self.budget) s budget")
    }

    /// A parse check still running when the budget is spent is the last one started: the files after it are not checked at all.
    @Test func noParseCheckStartsOnceTheBudgetIsSpent() throws {
        let marks = try ReuseNudgeMarks(directory: TemporaryDirectory.make("nudge-marks"))
        let payloads: [[String: Any]] = (0 ..< 3).map { index in
            ["tool_name": "Edit", "tool_input": ["file_path": "/nowhere/Shelf\(index).swift"], "session_id": "s1"]
        }
        var started = 0

        PostToolUseCommand.answer(toEach: payloads, output: RecordedOutput().output, marks: marks, timeBudget: Self.budget) { _, _, _ in
            started += 1
            Thread.sleep(forTimeInterval: Self.budget * 2)
            return nil
        }

        #expect(started == 1)
    }
}
