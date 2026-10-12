//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A full run's crash answer names the bundle and the signal from SwiftPM's line even when it is glued to a test-case line, and lists only the last few tests that started and never ended.
struct RunCrashGluedLineTests {
    private static var helper: String {
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    }

    private static func log(started: Int) -> String {
        let signal = "error: Process '\(helper) --test-bundle-path /Users/dev/Pallet/.build/out/Products/Debug/PalletTests.xctest --event-stream-output-path /var/tmp/event-stream-0-PalletTests.jsonl /Users/dev/Pallet/.build/out/Products/Debug/PalletTests.xctest --testing-library swift-testing' exited with unexpected signal code 5"
        var lines = [
            "Building for debugging...",
            "Build complete! (0.33 secs)",
            "◇ Test case passing 1 argument line → \"cd /tmp || true && sift digest Beta\"" + signal,
            "◇ Test run started.",
            "◇ Test loads() started.",
            "✔ Test loads() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
            "◇ Test run started.",
        ]
        lines += (1 ... started).map { "◇ Test crowd\($0)() started." }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test
    func theBundleTheSignalAndTheLastFiveStartedAreNamed() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data(Self.log(started: 40).utf8))
        let report = filter.finish(exitCode: 1)

        #expect(report.verdict?.state == .failed)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
        let line = try #require(answer.split(separator: "\n").first { $0.contains("test process exited on signal") })
        #expect(line.contains("PalletTests test process exited on signal 5 (SIGTRAP); last started: "))
        let names = line.components(separatedBy: "last started: ")[1].components(separatedBy: ", ")
        #expect(names == (36 ... 40).map { "crowd\($0)()" })
    }
}
