//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a test printing a line in a diagnostic's shape behind other words: the compiler and XCTest print their path at the head of the line, so a printed command or sentence ahead of the path makes it no failure and no compiler error, while a real path holding a space still counts.
struct RunPrintedDiagnosticLineTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)
    private static var echoedAssertion: String {
        "/bin/echo said /x/T.swift:12: error: -[T.A b] : boom"
    }

    private static var echoedError: String {
        "said /x/T.swift:13: error: boom"
    }

    private static var quotedAssertion: String {
        #"/bin/echo said "/x/T.swift:12: error: -[T.A b] : boom"#
    }

    private static var echoedMacroBuffer: String {
        "said /tmp/@__swiftmacro_A.swift:1:1: error: boom"
    }

    private static var spacedAssertion: String {
        "/Users/x/My Project/Tests/GizmoTests/GizmoTests.swift:3: error: -[GizmoTests.GizmoTests testDoubling] : XCTAssertTrue failed"
    }

    private static var spacedError: String {
        "/Users/x/My Project/Sources/Gizmo/Gizmo.swift:3:8: error: cannot find 'widget' in scope"
    }

    /// The live state after `lines` arrive, each with its newline, in one chunk.
    private static func live(_ lines: [String]) -> RunLiveState {
        var tally = RunLiveTally(startedAt: start)
        tally.consume(Data(lines.map { $0 + "\n" }.joined().utf8), now: start)
        _ = tally.finish(now: start)
        return tally.state
    }

    /// The report the finished filter builds from `lines` for a `swift test` exiting with `exitCode`.
    private static func report(_ lines: [String], exitCode: Int32) -> RunReport {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: exitCode)
    }

    /// A passing Swift Testing run with `printed` among its output.
    private static func greenRun(printing printed: String) -> [String] {
        [
            "◇ Test run started.",
            "◇ Test echoes() started.",
            printed,
            "✔ Test echoes() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ]
    }

    /// Text ahead of a path is no diagnostic: neither the printed command, the quoted one, nor the sentence parses as one.
    @Test(arguments: [echoedAssertion, echoedError, quotedAssertion, echoedMacroBuffer])
    func aDiagnosticBehindPrintedWordsIsNone(line: String) {
        #expect(RunDiagnostic.parse(line) == nil)
    }

    /// A printed command quoting an XCTest failure fails no test: the run stays green and lists nothing.
    @Test
    func anEchoedXCTestFailureLeavesTheRunGreen() {
        let lines = Self.greenRun(printing: Self.echoedAssertion)
        let state = Self.live(lines)
        let report = Self.report(lines, exitCode: 0)

        #expect(state.tests.failed == 0)
        #expect(state.errors == 0)
        #expect(report.testFailures.isEmpty)
        #expect(report.errors.isEmpty)
        #expect(report.verdict?.state == .succeeded)
    }

    /// A printed sentence ending in a compiler error's shape is no compiler error, live or in the report.
    @Test
    func anEchoedCompilerErrorIsNoError() {
        let lines = Self.greenRun(printing: Self.echoedError)
        let state = Self.live(lines)
        let report = Self.report(lines, exitCode: 0)

        #expect(state.errors == 0)
        #expect(report.errors.isEmpty)
        #expect(report.verdict?.state == .succeeded)
    }

    /// A real XCTest failure under a path holding a space is still a failure, named and located.
    @Test
    func anXCTestFailureUnderASpacedPathStillFails() throws {
        let lines = [
            "Test Case '-[GizmoTests.GizmoTests testDoubling]' started.",
            Self.spacedAssertion,
            "Test Case '-[GizmoTests.GizmoTests testDoubling]' failed (0.001 seconds).",
        ]
        let report = Self.report(lines, exitCode: 1)
        let failure = try #require(report.testFailures.first)

        #expect(report.testFailures.count == 1)
        #expect(failure.name == "-[GizmoTests.GizmoTests testDoubling]")
        #expect(failure.location == "/Users/x/My Project/Tests/GizmoTests/GizmoTests.swift:3")
        #expect(report.errors.isEmpty)
    }

    /// A real compiler error under a path holding a space is still an error, live and in the report.
    @Test
    func aCompilerErrorUnderASpacedPathStillCounts() throws {
        let diagnostic = try #require(RunDiagnostic.parse(Self.spacedError))
        let state = Self.live([Self.spacedError])
        let report = Self.report([Self.spacedError, "error: Build failed"], exitCode: 1)

        #expect(diagnostic.path == "/Users/x/My Project/Sources/Gizmo/Gizmo.swift")
        #expect(diagnostic.line == 3)
        #expect(diagnostic.column == 8)
        #expect(state.errors == 1)
        #expect(report.errors.count == 1)
    }
}
