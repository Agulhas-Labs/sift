//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `run --without-line` rewrites a line to `_ = name` only when the line is a whole bare assignment, and the answer matches a compiler's path only at a path boundary.
struct WithoutLineStatementTests {
    /// The first line of a statement that goes on to the next is not a bare assignment: rewriting it would leave the continuation as a call on the name.
    @Test(arguments: [
        "    settings = updated\n        .merged()",
        "    settings = updated\n        ?? fallback",
        "    settings = updated\n    { report(settings) }",
        "    settings = updated; other = 1",
    ])
    func theFirstLineOfALongerStatementIsNotABareAssignment(statement: String) throws {
        let source = "func run() {\n\(statement)\n}\n"

        #expect(SetAsideRecord.MutatedLine.bareAssignment(inFile: source, line: 2) == nil)
        let (_, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: Data(source.utf8), path: "Widget.swift")

        #expect((String(bytes: mutated, encoding: .utf8) ?? "").contains("    // settings = updated"))
    }

    /// A one-line assignment still qualifies, and says so in what it returns.
    @Test
    func aOneLineAssignmentStillQualifies() throws {
        let source = "func run() {\n    settings = updated\n}\n"

        #expect(SetAsideRecord.MutatedLine.bareAssignment(inFile: source, line: 2)?.name == "updated")
        let (_, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: Data(source.utf8), path: "Widget.swift")

        #expect(SetAsideRecord.MutatedLine.bareAssignment(inFile: source, line: 2)?.replacement == "_ = updated")
        #expect((String(bytes: mutated, encoding: .utf8) ?? "") == "func run() {\n    _ = updated\n}\n")
    }

    /// A line that already discards its value is not rewritten to itself: it is commented out like any other line.
    @Test
    func anUnderscoreTargetIsNotABareAssignment() throws {
        let source = "func run() {\n    _ = updated\n}\n"

        #expect(SetAsideRecord.MutatedLine.bareAssignment(inFile: source, line: 2) == nil)
        let (_, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: Data(source.utf8), path: "Widget.swift")

        #expect((String(bytes: mutated, encoding: .utf8) ?? "") == "func run() {\n    // _ = updated\n}\n")
    }

    /// A compiler path in another directory that merely ends in the same characters is not the set-aside file.
    @Test
    func aPathThatOnlyEndsTheSameIsNotTheFile() {
        let unused = "OtherSources/Widget.swift:5:16: error: value 'updated' was defined but never used; consider replacing with boolean test\n"
        let record = SetAsideRecord(
            id: "0123456789",
            pathspecs: ["Sources/Widget.swift:6"],
            directory: "",
            head: String(repeating: "a", count: 40),
            owner: 1,
            entries: [],
            line: SetAsideRecord.MutatedLine(path: "Sources/Widget.swift", number: 6, text: "        settings = merged(updated)")
        )
        let answer = RunWithoutAnswer(
            pathspecs: "Sources/Widget.swift:6",
            without: RunWithoutAnswerTests.failedBeforeTests(unused),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true]),
            restored: SetAside.Restored(record: record, kept: [], headNow: nil),
            workingDirectory: URL(fileURLWithPath: "/nonexistent"),
            repositoryRoot: URL(fileURLWithPath: "/nonexistent")
        ).render().text

        #expect(!answer.contains("set the line aside by hand"), "\(answer)")
    }
}
