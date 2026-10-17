//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Accessibility notes sit under the receipt, so the answer closes on its verdict below them: a `tail -3` keeps it however many devices owe a note.
@Suite(.temporaryDirectories)
struct RunVerdictUnderDeviceNotesTests {
    private static let first = SimulatorAccessibility.Restoration(udid: "11111111-1111-1111-1111-111111111111", state: .restored)
    private static let second = SimulatorAccessibility.Restoration(udid: "22222222-2222-2222-2222-222222222222", state: .restored)

    /// A build with no totals line and two device notes ends on the verdict, within the last three lines.
    @Test
    func aNoTotalsAnswerWithTwoNotesEndsOnItsVerdict() throws {
        let lines = try Self.lines(capture: "swift-build-success", invokedAs: ["swift", "build"], notes: [Self.first, Self.second])

        #expect(lines.last == "verdict: ✔ swift build")
        #expect(lines.suffix(3).contains("verdict: ✔ swift build"))
        #expect(lines.filter { $0.hasPrefix("verdict: ") }.count == 1)
    }

    /// A test answer with a `totals:` line and two device notes also ends on the verdict.
    @Test
    func aTestAnswerWithTwoNotesEndsOnItsVerdict() throws {
        let lines = try Self.lines(capture: "swift-test-pass", invokedAs: ["swift", "test"], notes: [Self.first, Self.second])

        #expect(lines.contains { $0.hasPrefix("totals:") })
        #expect(lines.last?.hasPrefix("verdict: ") == true)
        #expect(lines.filter { $0.hasPrefix("verdict: ") }.count == 1)
    }

    /// One note is enough to move the verdict below it.
    @Test
    func oneNoteLeavesTheVerdictLast() throws {
        let lines = try Self.lines(capture: "swift-build-success", invokedAs: ["swift", "build"], notes: [Self.first])

        #expect(lines.last == "verdict: ✔ swift build")
        #expect(lines[lines.count - 2].hasPrefix("accessibility:"))
    }

    /// The receipt's `N out` is the answer's real line count, the moved verdict line included.
    @Test
    func theReceiptCountsTheMovedVerdictLine() throws {
        for (capture, argv) in [("swift-build-success", ["swift", "build"]), ("swift-test-pass", ["swift", "test"])] {
            let lines = try Self.lines(capture: capture, invokedAs: argv, notes: [Self.first, Self.second])
            let receipt = try #require(lines.first { $0.hasPrefix("raw:") })

            #expect(receipt.contains(", \(lines.count) out)"))
        }
    }

    private static func lines(capture: String, invokedAs: [String], notes: [SimulatorAccessibility.Restoration]) throws -> [String] {
        let report = try TestSources.runReport(capture, invokedAs: invokedAs, exitCode: 0)
        let log = URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-1.log")
        let kind: RunCommandKind = invokedAs[1] == "test" ? .swiftTest : .swiftBuild
        let renderer = RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), accessibility: notes)
        return renderer.render(report, exitCode: 0, logURL: log).components(separatedBy: "\n")
    }
}
