//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the live tally against the finished report: however the output was cut into chunks, and whichever capture it read, the live count ends where the report's does.
struct RunLiveTallyParityTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    /// The state a tally ends in when it is handed `chunks` one after another and then finished.
    private static func state(fedInChunks chunks: [Data]) -> RunLiveState {
        var tally = RunLiveTally(startedAt: start)
        for chunk in chunks {
            tally.consume(chunk, now: start)
        }
        _ = tally.finish(now: start)
        return tally.state
    }

    /// A chunk boundary at any byte, inside a line, inside a multi-byte status glyph or a thin space, changes nothing: every split of the capture ends in the state the whole capture does.
    @Test(arguments: ["swift-test-fail", "swift-test-colored-warning-and-failure"])
    func aChunkBoundaryAtAnyByteChangesNothing(capture: String) throws {
        let bytes = try TestSources.runOutputData(capture, extension: "txt")
        let whole = Self.state(fedInChunks: [bytes])

        #expect(whole.tests.finished > 0)
        for offset in 0 ... bytes.count {
            let split = Self.state(fedInChunks: [bytes.prefix(offset), bytes.dropFirst(offset)].map { Data($0) })
            #expect(split == whole, "split at byte \(offset)")
        }
    }

    /// The live count of tests, errors and warnings equals the finished report's: its tests as ``RunTestOutcomes`` last saw each end, its errors and warnings as its diagnostics listed them.
    @Test(arguments: [
        ("swift-test-fail", ["swift", "test"]),
        ("swift-test-pass", ["swift", "test"]),
        ("swift-test-mixed-xctest-failure", ["swift", "test"]),
        ("swift-test-colored-warning-and-failure", ["swift", "test"]),
        ("swift-test-display-name", ["swift", "test"]),
        ("swift-build-success", ["swift", "build"]),
        ("xcodebuild-test-failure", ["xcodebuild", "test"]),
        ("xcodebuild-test-success", ["xcodebuild", "test"]),
        ("xcodebuild-retry-iterations", ["xcodebuild", "test"]),
    ])
    func theLiveCountEndsWhereTheReportsDoes(capture: String, invocation: [String]) throws {
        let bytes = try TestSources.runOutputData(capture, extension: "txt")
        let live = Self.state(fedInChunks: [bytes])
        let report = try TestSources.runReport(capture, invokedAs: invocation)
        let endings = report.testOutcomes.lastEndings.values

        #expect(live.tests.passed == endings.count { $0 == .passed })
        #expect(live.tests.failed == endings.count { $0 == .failed })
        #expect(live.tests.skipped == endings.count { $0 == .skipped })
        #expect(live.errors == report.errors.count)
        #expect(live.warnings == report.warnings.count)
    }

    /// Where no test repeats, the live count is also the tools' own: XCTest's outermost `Executed …` counter plus Swift Testing's run tally.
    @Test(arguments: [("swift-test-fail", 5), ("swift-test-pass", 4), ("xcodebuild-test-failure", 1)])
    func theLiveCountIsTheToolsOwnClosingCount(capture: String, closing: Int) throws {
        let bytes = try TestSources.runOutputData(capture, extension: "txt")
        let lines = try TestSources.runOutput(capture).components(separatedBy: "\n")
        let counters = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("Executed ") }
        let executed = counters.last.flatMap { RunOutputFilter.ExecutedCounts(line: $0)?.tests } ?? 0
        let tallied = try TestSources.runReport(capture, invokedAs: ["swift", "test"]).tally?.tests ?? 0

        #expect(executed + tallied == closing)
        #expect(Self.state(fedInChunks: [bytes]).tests.finished == closing)
    }
}
