//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The count of selected tests a crashed process never started is the count of its own bundle's, never every test the run's event stream declared.
struct RunTestCrashBundleScopeTests {
    /// `PalletTests`' Swift Testing process traps in `topples()` after `ToteStackTests`' process passed: the stream declares five tests across the two, and the crashed process was handed three.
    @Test
    func theNeverStartedCountIsTheCrashedBundlesOwn() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        try filter.consume(Data(TestSources.runOutput("swift-test-crash-st-lookalike").utf8))
        let stream = try TestSources.runOutputData("swift-test-crash-st-lookalike", extension: "jsonl")
        try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: stream, encoding: .utf8))))
        let report = filter.finish(exitCode: 1)

        #expect(report.verdict?.state == .failed)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("  Swift Testing test process exited on signal 5 while running topples(); 0 of 3 selected tests never started"))
    }
}
