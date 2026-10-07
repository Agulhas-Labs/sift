//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `run --without-line` on `settings = updated` — the one reader of `updated` — keeps the read, so the build that treats warnings as errors does not stop on an unused value; and when a line it could not rewrite still leaves only unused-value errors, the answer says how to set it aside by hand.
@Suite(.temporaryDirectories)
struct WithoutLineBindingTests {
    /// Where the rewrite applies, the line becomes `_ = name` — target replaced, indentation, line ending, semicolon and trailing comment as they were.
    @Test(arguments: [
        ("        settings = updated", "        _ = updated"),
        ("settings = updated\r", "_ = updated\r"),
        ("    self.settings = updated; // keep", "    _ = updated; // keep"),
        ("\tstore[0] = updated", "\t_ = updated"),
        ("    model?.settings = updated", "    _ = updated"),
    ])
    func aBareIdentifierAssignmentIsSetAsideAsAnUnderscoreRead(line: String, setAside: String) throws {
        let source = Data("func run() {\n\(line)\n}\n".utf8)

        let (text, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: source, path: "Widget.swift")

        #expect(text == line)
        #expect(mutated == Data("func run() {\n\(setAside)\n}\n".utf8), "\(String(bytes: mutated, encoding: .utf8) ?? "")")
    }

    /// Every other line keeps the form it had: commented out after its indentation.
    @Test(arguments: [
        "        settings = merged(updated)",
        "        settings = updated.merged()",
        "        settings = updated.value",
        "        settings = updated + 1",
        "        settings = \"fixed\"",
        "        settings = nil",
        "        settings += updated",
        "        let settings = updated",
        "        var settings = updated",
        "        guard let settings = updated else { return }",
        "        report(updated)",
        "        return updated",
        "        if ready { settings = updated }",
        "        settings = updated ?? 1",
    ])
    func anyOtherLineIsStillCommentedOut(line: String) throws {
        let source = Data("func run() {\n\(line)\n}\n".utf8)

        let (_, mutated) = try SetAsideRecord.MutatedLine.commentingOut(line: 2, of: source, path: "Widget.swift")

        let indentation = String(line.prefix { $0 == " " })

        #expect((String(bytes: mutated, encoding: .utf8) ?? "") == "func run() {\n\(indentation)// \(line.dropFirst(indentation.count))\n}\n")
        #expect(SetAsideRecord.MutatedLine.bareAssignment(inFile: "func run() {\n\(line)\n}\n", line: 2) == nil)
    }

    /// The receipt says which form was used, from the line it quotes.
    @Test
    func theReceiptNamesTheFormUsed() {
        let bare = Self.record(text: "        settings = updated", replacement: "_ = updated")
        let call = Self.record(text: "        settings = merged(updated)")

        let first = RunWithoutAnswer.setAsideLine(bare, pathspecs: "Sources/Widget.swift:6")
        let second = RunWithoutAnswer.setAsideLine(call, pathspecs: "Sources/Widget.swift:6")

        #expect(first == "  set aside: Sources/Widget.swift:6 — \"settings = updated\" (set aside as `_ = updated` for the run without the change)", "\(first)")
        #expect(second == "  set aside: Sources/Widget.swift:6 — \"settings = merged(updated)\" (commented out for the run without the change)", "\(second)")
    }

    /// A run without the change that stopped on nothing but unused values the set-aside line read names the hand form, once, after the errors.
    @Test
    func unusedValuesTheLineReadNameTheHandForm() {
        let log = """
        Sources/Widget.swift:5:16: error: value 'updated' was defined but never used; consider replacing with boolean test
        error: fatalError

        """

        let answer = Self.judged(text: "        settings = merged(updated)", log: log).render().text
        let hints = answer.split(separator: "\n").filter { $0.contains("set the line aside by hand") }

        #expect(hints.count == 1, "\(answer)")
        #expect(hints.first == "  the only errors are unused values that Sources/Widget.swift:6 read (updated): set the line aside by hand as `_ = updated` in its place so the name keeps a reader, or run `--without` on the fix's file", "\(answer)")
    }

    /// Any other error beside the unused value, a value the line never read, and a run that was not a line set-aside each leave the answer as it was.
    @Test
    func theHintStaysSilentWhereItWouldBeWrong() {
        let unused = "Sources/Widget.swift:5:16: error: value 'updated' was defined but never used; consider replacing with boolean test\n"
        let other = "Sources/Widget.swift:9:3: error: cannot find 'Gadget' in scope\n"
        let unrelated = "Sources/Widget.swift:5:16: error: value 'counter' was defined but never used; consider replacing with boolean test\n"
        let elsewhere = "Sources/Other.swift:5:16: error: value 'updated' was defined but never used; consider replacing with boolean test\n"
        let text = "        settings = merged(updated)"

        for log in [unused + other, unrelated, elsewhere, other] {
            let answer = Self.judged(text: text, log: log).render().text
            #expect(!answer.contains("set the line aside by hand"), "\(log): \(answer)")
        }
        let whole = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(unused),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true])
        ).render().text

        #expect(!whole.contains("set the line aside by hand"), "\(whole)")
    }

    private static func record(text: String, replacement: String? = nil) -> SetAsideRecord {
        SetAsideRecord(
            id: "0123456789",
            pathspecs: ["Sources/Widget.swift:6"],
            directory: "",
            head: String(repeating: "a", count: 40),
            owner: 1,
            entries: [],
            line: SetAsideRecord.MutatedLine(path: "Sources/Widget.swift", number: 6, text: text, replacement: replacement)
        )
    }

    private static func judged(text: String, log: String) -> RunWithoutAnswer {
        RunWithoutAnswer(
            pathspecs: "Sources/Widget.swift:6",
            without: RunWithoutAnswerTests.failedBeforeTests(log),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true]),
            restored: SetAside.Restored(record: record(text: text), kept: [], headNow: nil),
            workingDirectory: URL(fileURLWithPath: "/nonexistent"),
            repositoryRoot: URL(fileURLWithPath: "/nonexistent")
        )
    }
}
