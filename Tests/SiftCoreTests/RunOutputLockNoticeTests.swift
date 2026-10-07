//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// SwiftPM's unterminated `.build` lock notice, glued onto the line a test process opens with: split off before the process is counted.
struct RunOutputLockNoticeTests {
    /// The notice as a real `swift test --ignore-lock` shard printed it, with no newline after it.
    private static var ignoredNotice: String {
        "Another instance of SwiftPM (PID: 68518) is already running using '/src/Lib/.build', but this will be ignored since `--ignore-lock` has been passed"
    }

    private static var waitingNotice: String {
        "Another instance of SwiftPM (PID: 4242) is already running using '/src/Lib/.build', waiting until that process has finished execution..."
    }

    /// The captured mixed-framework transcript with `notice` glued onto the first line that begins with `opening`, as a log of both streams holds it.
    private static func report(gluing notice: String, onto opening: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunReport {
        let lines = try TestSources.runOutput("swift-test-mixed-xctest-failure").components(separatedBy: "\n")
        let index = try #require(lines.firstIndex { RunOutputFilter.undecorated($0.trimmingCharacters(in: .whitespaces)).hasPrefix(opening) }, sourceLocation: sourceLocation)
        var glued = lines
        glued[index] = notice + lines[index]
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data(glued.joined(separator: "\n").utf8))
        return filter.finish(exitCode: 1)
    }

    @Test func anXCTestOpeningBehindTheIgnoredLockNoticeIsStillCounted() throws {
        let report = try Self.report(gluing: Self.ignoredNotice, onto: "Test Suite 'All tests' started at")

        #expect(report.testProcessOpenings == 2)
        #expect(report.testProcessOpenings == report.testProcessClosings)
    }

    @Test func aSwiftTestingOpeningBehindTheWaitingNoticeIsStillCounted() throws {
        let report = try Self.report(gluing: Self.waitingNotice, onto: "Test run started.")

        #expect(report.swiftTestingProcessOpenings == 1)
        #expect(report.testProcessOpenings == 2)
    }

    @Test func aNoticeOnALineOfItsOwnIsLeftWhole() {
        #expect(RunOutputFilter.splitLockNotice(Self.waitingNotice) == nil)
        #expect(RunOutputFilter.splitLockNotice("Test run started.") == nil)
    }
}
