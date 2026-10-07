import Foundation
@testable import SiftCore
import Testing

/// A `swift test` whose test process trapped reads as a crash: the trap's line, the test it died in, what never started, and a `crashed` totals word over another bundle's passing count.
struct RunTestProcessCrashTests {
    /// The Swift Testing process traps on a force-unwrap while XCTest's bundle passes: the answer names the trap and the test, and never leads with XCTest's pass.
    @Test
    func aSwiftTestingTrapNamesTheFatalErrorAndTheTestItDiedIn() throws {
        let arguments = ["swift", "test", "--filter", "topples", "--filter", "testStacks"]
        var filter = RunOutputFilter(invokedAs: arguments)
        try filter.consume(Data(TestSources.runOutput("swift-test-crash-st").utf8))
        let stream = try TestSources.runOutputData("swift-test-crash-st", extension: "jsonl")
        try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: stream, encoding: .utf8))))
        let report = filter.finish(exitCode: 1)

        #expect(report.verdict?.state == .failed)
        #expect(report.errors.isEmpty)
        #expect(report.isUsable(exitCode: 1))
        let answer = Self.answer(report)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — exit 1 — test process crashed")
        #expect(lines.dropFirst().first == "  PalletTests/Stacking.swift:4: Fatal error: Unexpectedly found nil while unwrapping an Optional value")
        #expect(answer.contains("  Swift Testing test process exited on signal 5 while running topples(); 0 of 1 selected test never started"))
        #expect(lines.contains { $0.hasPrefix("totals: ✘ crashed — 1 of 2 test processes printed a closing count") })
        #expect(!answer.contains("error: Process"))
        #expect(RunOutcome(kind: .swiftTest, logKey: "", exitCode: 1, report: report, log: nil, repositoryRoot: nil).reportedTestFailures == nil)
    }

    /// The XCTest process traps on an index out of range while Swift Testing's bundle passes: the answer is a crash, not a pass the exit code disagrees with.
    @Test
    func anXCTestTrapNamesTheTestAndCountsTheSelectionItNeverStarted() throws {
        let report = try TestSources.runReport("swift-test-crash-xc", invokedAs: ["swift", "test", "--filter", "testStacks", "--filter", "testBuckles", "--filter", "testLoads", "--filter", "loads"], exitCode: 1)

        #expect(report.verdict?.state == .failed)
        #expect(report.errors.isEmpty)
        let answer = Self.answer(report)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — exit 1 — test process crashed")
        #expect(lines.dropFirst().first == "  Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range")
        #expect(answer.contains("  XCTest test process exited on signal 5 while running -[PalletTests.PalletTests testBuckles]; 2 of 3 selected tests never started"))
        #expect(lines.contains { $0.hasPrefix("totals: ✘ crashed — 1 of 2 test processes printed a closing count") })
        #expect(!answer.contains("declares success"))
        #expect(!answer.contains("exit code disagrees"))
    }

    /// A green run of the same package carries no crash and keeps its pass.
    @Test
    func aGreenRunOfTheSamePackageCarriesNoCrash() throws {
        let report = try TestSources.runReport("swift-test-crash-green", invokedAs: ["swift", "test", "--filter", "stacks", "--filter", "testStacks"], exitCode: 0)

        #expect(report.testCrash == nil)
        #expect(report.verdict?.state == .succeeded)
        #expect(!Self.answer(report, exitCode: 0).contains("crashed"))
    }

    /// A test that prints trap-shaped text without any process dying is no crash, and its line is no trap.
    @Test
    func trapTextWithNoSignalLineIsNoCrash() {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(line: "Shelf/Rack.swift:9: Fatal error: printed by a passing test")

        #expect(filter.finish(exitCode: 0).testCrash == nil)
        #expect(!RunTestCrash.Reader.isTrap("note: Fatal error is a phrase"))
        #expect(RunTestCrash.Reader.isTrap("Shelf/Rack.swift:9: Precondition failed: shelf full"))
    }

    private static func answer(_ report: RunReport, exitCode: Int32 = 1) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: exitCode, logURL: nil)
    }
}
