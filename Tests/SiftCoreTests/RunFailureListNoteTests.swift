//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A failing expectation whose message is a short list is the answer the run owes, so it is printed as the list it is rather than folded onto one line and cut.
struct RunFailureListNoteTests {
    private func answer(noting lines: [String]) -> [String] {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test aFailingTest() recorded an issue at WidgetTests.swift:9:9: Expectation failed: wrong.isEmpty")
        for line in lines {
            filter.consume(line: line)
        }
        filter.consume(line: "✘ Test aFailingTest() failed after 0.002 seconds with 1 issue.")
        return RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(filter.finish(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    @Test
    func aShortListMessageIsShownWholeOneEntryPerLine() throws {
        let entries = (1 ... 6).map { "Tests/WidgetTests/File\($0).swift:\($0 * 10)  WidgetRow" }
        let lines = answer(noting: ["↳ 6 names said in the tree are not permitted by the list:"] + entries.map { "    \($0)" })

        let head = try #require(lines.firstIndex { $0.hasPrefix("    ↳ 6 names said in the tree are not permitted by the list:") })

        #expect(Array(lines.dropFirst(head + 1).prefix(6)) == entries.map { "      \($0)" })
        #expect(!lines.contains { $0.contains("more lines") })
    }

    @Test
    func aLongListMessageIsFoldedAfterTheBudgetWithTheRawLogTail() {
        let entries = (1 ... 39).map { "entry \($0)" }
        let lines = answer(noting: ["↳ 39 entries:"] + entries.map { "    \($0)" })

        #expect(lines.contains("      entry 11"))
        #expect(!lines.contains("      entry 12"))
        #expect(lines.contains("      … (+28 more lines — see the raw log)"))
    }

    @Test
    func aLongSingleLineMessageKeepsTheOneLineFold() {
        let lines = answer(noting: ["↳ " + String(repeating: "word ", count: 100)])

        let note = lines.filter { $0.hasPrefix("    ↳ word") }

        #expect(note.count == 1)
        #expect(note.first?.contains("characters — see the raw log") == true)
        #expect(!lines.contains { $0.hasPrefix("      ") })
    }
}
