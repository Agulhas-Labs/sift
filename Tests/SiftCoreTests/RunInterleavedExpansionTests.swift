//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a `↳` line from another test landing inside a failure's block under a parallel run, which the depth Swift Testing prints it at tells from the failure's own reads.
///
/// `Fixtures/RunOutput/swift-test-interleaved-expansions.txt` is the nil-reads capture's shape with twelve failures that read twelve different values, and a foreign test's expansions printed inside seven of their blocks.
struct RunInterleavedExpansionTests {
    /// Twelve failures with twelve values of their own are no class, however many foreign `nil` reads landed among them.
    @Test
    func aForeignExpansionInsideABlockIsNotOneOfItsReads() throws {
        let report = try TestSources.runReport("swift-test-interleaved-expansions", invokedAs: ["swift", "test"], exitCode: 1)
        let failures = report.testFailures

        #expect(failures.count == 12)
        #expect(Set(failures.compactMap { $0.location?.split(separator: ":").first }).count == 3)
        #expect(failures[0].markedLines == ["c(0) == \"ok\" → false", "  c(0) → \"v0\"", "q == .none → false", "  q → nil"])
        #expect(failures[11].markedLines == ["e(11) == \"ok\" → false", "  e(11) → \"v11\""])
        #expect(Self.shape(of: failures.map(Self.shapeFailure)).dominantClass == nil)
    }

    /// The console keeps each `↳` line's depth in the failure's marked lines, and the note that every other reader joins stays flat.
    @Test
    func theConsoleKeepsTheDepthOfEachLine() throws {
        let report = try TestSources.runReport("swift-test-nil-reads", invokedAs: ["swift", "test"], exitCode: 1)
        let helper = try #require(report.testFailures.first { $0.markedLines.first == "label(of: 4) == \"x4\" → false" })
        let multiLine = try #require(report.testFailures.first { $0.message.contains("\"note 6\"") })
        let first = try #require(multiLine.markedLines.dropFirst().first)

        #expect(helper.markedLines == ["label(of: 4) == \"x4\" → false", "  label(of: 4) → nil", "    some → \"x4\""])
        #expect(helper.note == "label(of: 4) == \"x4\" → false label(of: 4) → nil some → \"x4\"")
        #expect(first.hasPrefix("  Gizmo.soleElement("))
        #expect(!first.hasPrefix("   "))
        #expect(first.hasSuffix("→ nil"))
    }

    /// An unindented line after the whole expression is another expectation's whole, so it and what follows it are not this failure's reads.
    @Test
    func anUnindentedLineAfterTheWholeEndsTheRun() {
        let failures = (0 ..< 8).map { Self.failure($0, indented: true) }

        #expect(Self.shape(of: failures).dominantClass == nil)
    }

    /// Lines with no depth at all, as the event stream and a flush fixture give them, are read to the end as before; this passes on the base too.
    @Test
    func linesWithNoDepthAreReadAsBefore() {
        let failures = (0 ..< 8).map { Self.failure($0, indented: false) }

        #expect(Self.shape(of: failures).dominantClass?.line == "  ↳ 8 of 8 failures read one and the same value (bay.count == .none → false), across 8 signatures")
    }
}

private extension RunInterleavedExpansionTests {
    /// The shape of `failures`, with nothing changed.
    static func shape(of failures: [RunFailureShape.Failure]) -> RunFailureShape {
        RunFailureShape.of(failures, changedFiles: .of([]))
    }

    /// A console failure as the answer's shape carries it.
    static func shapeFailure(_ failure: RunTestFailure) -> RunFailureShape.Failure {
        RunFailureShape.Failure(
            name: failure.name,
            location: failure.location,
            message: failure.message,
            arguments: failure.arguments,
            note: failure.note,
            markedLines: failure.markedLines
        )
    }

    /// A failure on its own property compared to `"ok"` with a value of its own, then another test's `bay.count` read, indented or flush.
    static func failure(_ index: Int, indented: Bool) -> RunFailureShape.Failure {
        let pad = indented ? "  " : ""
        let property = ["depth", "height", "width", "index", "total", "limit", "level", "size"][index]
        return RunFailureShape.Failure(
            name: "aTestNamed\(index)()",
            location: "Sprocket\(index)Tests.swift:\(index + 1):9",
            message: "Expectation failed: \(property) == \"ok\"",
            note: nil,
            markedLines: [
                "\(property) == \"ok\" → false",
                "\(pad)\(property) → \"v\(index)\"",
                "bay.count == .none → false",
                "\(pad)bay.count → nil",
            ]
        )
    }
}
