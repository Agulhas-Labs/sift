//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A red run whose failure section leaves tests unnamed ends on one block listing every failing test under its file, and says nothing more where the section already named them all.
struct RunFailingByFileTests {
    private static var heading: String {
        "failing tests by file:"
    }

    private static var repeated: String {
        "Expectation failed: kettle.isEmpty"
    }

    private func issues(_ count: Int, in file: String, prefix: String, message: String = repeated) -> [Issue] {
        (1 ... count).map { Issue(test: "\(prefix)\($0)()", file: file, message: message) }
    }

    /// The whole answer for a Swift Testing run that recorded `issues`, padded with passes so the log is long enough for any block to fit.
    private func answer(_ issues: [Issue], extra: [String] = []) -> [String] {
        var filter = RunOutputFilter(expecting: .runTally)
        for pass in 1 ... 400 {
            filter.consume(line: "✔ Test steeps\(pass)() passed after 0.001 seconds.")
        }
        for issue in issues {
            filter.consume(line: "✘ Test \(issue.test) recorded an issue at \(issue.file):9:9: \(issue.message)")
            for line in extra {
                filter.consume(line: line)
            }
            filter.consume(line: "✘ Test \(issue.test) failed after 0.002 seconds with 1 issue.")
        }
        return RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(filter.finish(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// The block's own lines: the heading and the indented lines under it.
    private func block(of lines: [String]) -> [String] {
        guard let start = lines.firstIndex(of: Self.heading) else {
            return []
        }
        return [Self.heading] + lines[(start + 1)...].prefix { $0.hasPrefix("  ") }
    }

    @Test
    func failuresAcrossThreeFilesWithElidedSignaturesAreEveryOneListedAndCountedByFile() {
        let failing = issues(5, in: "GizmoTests.swift", prefix: "pot")
            + issues(4, in: "KettleTests.swift", prefix: "cup", message: "Expectation failed: leaf.isEmpty")
            + issues(3, in: "GadgetTests.swift", prefix: "lid")
        let lines = answer(failing)

        let above = lines.prefix { $0 != Self.heading }

        #expect(!above.contains { $0.contains("pot5()") })
        #expect(block(of: lines) == [
            Self.heading,
            "  GizmoTests.swift (5): pot1(), pot2(), pot3(), pot4(), pot5()",
            "  KettleTests.swift (4): cup1(), cup2(), cup3(), cup4()",
            "  GadgetTests.swift (3): lid1(), lid2(), lid3()",
        ])
    }

    @Test
    func filesAreOrderedByFailingTestCountThenByName() {
        let failing = issues(2, in: "GizmoTests.swift", prefix: "pot")
            + issues(4, in: "GadgetTests.swift", prefix: "lid")
            + issues(2, in: "KettleTests.swift", prefix: "cup")
        let lines = block(of: answer(failing))

        #expect(lines.dropFirst().map { $0.split(separator: " ")[0] } == ["GadgetTests.swift", "GizmoTests.swift", "KettleTests.swift"])
    }

    @Test
    func seventyFailingTestsPrintSixtyNamesAndCountTheRest() throws {
        let failing = issues(25, in: "GizmoTests.swift", prefix: "pot")
            + issues(25, in: "KettleTests.swift", prefix: "cup")
            + issues(20, in: "GadgetTests.swift", prefix: "lid")
        let lines = block(of: answer(failing))

        let names = lines.dropFirst().flatMap { line -> [String] in
            guard let colon = line.firstIndex(of: ":") else {
                return []
            }
            return line[line.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        #expect(names.count == 60)
        #expect(lines.last == "  +10 more failing tests in 1 file")
        #expect(lines.contains { $0.hasPrefix("  GadgetTests.swift (20): lid1()") })
        let lid = try #require(lines.first { $0.hasPrefix("  GadgetTests.swift") })
        #expect(!lid.contains("lid11()"))
        #expect(lid.hasSuffix("lid10()"))
    }

    @Test
    func aTestNameQuotedInsideAnExpectationArgumentIsNotATest() {
        let quoted = #"Expectation failed: names == ["✘ Test boils() recorded an issue at KettleTests.swift:3:3: x"]"#
        let failing = issues(6, in: "GizmoTests.swift", prefix: "pot", message: quoted)
        let lines = answer(failing, extra: [#"  ↳ names → ["✘ Test boils() failed after 0.002 seconds with 1 issue."]"#])

        let listed = block(of: lines)

        #expect(listed.first == Self.heading)
        #expect(listed.dropFirst().joined().contains("pot1()"))
        #expect(!listed.joined().contains("boils"))
        #expect(!listed.contains { $0.contains("KettleTests.swift") })
    }

    @Test
    func everyTestAlreadyNamedWithItsFileLeavesNoBlock() {
        let listing = answer(issues(2, in: "GizmoTests.swift", prefix: "pot") + issues(2, in: "KettleTests.swift", prefix: "cup", message: "Expectation failed: leaf.isEmpty"))
        #expect(listing.contains { $0.contains("pot1()") })
        #expect(!listing.contains(Self.heading))

        let sampled = answer((1 ... 8).map { _ in Issue(test: "pot()", file: "GizmoTests.swift", message: Self.repeated) })
        #expect(sampled.contains { $0.contains("×") })
        #expect(!sampled.contains(Self.heading))
    }

    @Test
    func aFailureThatNamedNoFileIsGroupedUnderNoLocation() {
        var filter = RunOutputFilter(expecting: .runTally)
        for pass in 1 ... 200 {
            filter.consume(line: "✔ Test steeps\(pass)() passed after 0.001 seconds.")
        }
        filter.consume(line: "✘ Test pot() recorded an issue: Expectation failed: kettle.isEmpty")
        filter.consume(line: "✘ Test pot() failed after 0.002 seconds with 1 issue.")
        let lines = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(filter.finish(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(block(of: lines) == [Self.heading, "  (no location) (1): pot()"])
    }

    @Test
    func anXCTestLogIsGroupedTheSameWayUnderItsClassAndMethod() {
        var filter = RunOutputFilter(expecting: .runTally)
        let failing = [
            ("GizmoTests", ["testOne", "testTwo", "testThree", "testNope"]),
            ("KettleTests", ["testX", "testA", "testB"]),
        ]
        for (suite, methods) in failing {
            for method in methods {
                let name = "-[WidgetTests.\(suite) \(method)]"
                filter.consume(line: "Test Case '\(name)' started.")
                filter.consume(line: "/Users/dev/Widget/Tests/WidgetTests/\(suite).swift:10: error: \(name) : XCTAssertEqual failed: (\"cold\") is not equal to (\"hot\")")
                filter.consume(line: "Test Case '\(name)' failed (0.002 seconds).")
            }
        }
        for pass in 1 ... 200 {
            filter.consume(line: "Test Case '-[WidgetTests.GadgetTests testPasses\(pass)]' passed (0.001 seconds).")
        }
        let lines = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(filter.finish(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(block(of: lines) == [
            Self.heading,
            "  GizmoTests.swift (4): GizmoTests.testOne, GizmoTests.testTwo, GizmoTests.testThree, GizmoTests.testNope",
            "  KettleTests.swift (3): KettleTests.testX, KettleTests.testA, KettleTests.testB",
        ])
    }

    @Test
    func theBlockIsOmittedWhereTheLogHasNoRoomLeftForIt() {
        var filter = RunOutputFilter(expecting: .runTally)
        for issue in issues(6, in: "GizmoTests.swift", prefix: "pot") {
            filter.consume(line: "✘ Test \(issue.test) recorded an issue at \(issue.file):9:9: \(issue.message)")
        }
        let lines = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(filter.finish(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(!lines.contains(Self.heading))
    }
}

extension RunFailingByFileTests {
    /// One Swift Testing failure: the test, the file it failed in, and the sentence it recorded.
    struct Issue {
        let test: String
        let file: String
        let message: String
    }
}
