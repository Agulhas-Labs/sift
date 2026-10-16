//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the dominant value read from Swift Testing's `↳` expansions, where each subexpression is printed on a line of its own beneath the issue rather than inside its message.
///
/// `Fixtures/RunOutput/swift-test-nil-reads.txt` is the real run: 40 of its 42 failures read `nil`, and every one of those reads is printed on a `↳` line, so a reader of the messages alone found no value at all.
@Suite(.temporaryDirectories)
struct RunArrowExpansionDominantTests {
    /// The real capture leads its census with the one value nearly every failure read.
    @Test
    func theCapturesNilReadsLeadTheBlock() throws {
        let block = try Self.captureBlock()
        try #require(block.count > 3)

        #expect(block[1].hasPrefix("  ↳ top: "))
        #expect(block[2] == "  ↳ 40 of 42 failures read one and the same value (Gizmo.soleElement(of: Self.band(), width: Self.bodyWidth)?.label → nil), across 5 signatures")
    }

    /// Failed comparisons whose operands share nothing read nothing in common: the `false` every one of them evaluated to is the failure itself, not a value it read.
    @Test
    func anExpectationsOwnResultIsNotAValueItRead() {
        let failures = Self.properties.enumerated().map { index, property in
            Self.failure(index, expression: "bay.\(property) == 0", markedLines: [
                "bay.\(property) == 0 → false",
                "bay.\(property) → \(index + 1)",
            ])
        }
        let shape = RunFailureShape.of(failures, changedFiles: .of([]))

        #expect(shape.signatureCount == Self.properties.count)
        #expect(shape.dominantClass == nil)
    }

    /// A comment is printed above the expansions as a `↳` line of its own, and an arrow inside it is the author's text, never a value.
    @Test
    func aCommentAboveTheExpansionsIsNeverRead() {
        let failures = Self.properties.enumerated().map { index, property in
            Self.failure(index, expression: "bay.\(property) == 0", markedLines: [
                "the signage reads labels → really",
                "bay.\(property) == 0 → false",
                "bay.\(property) → \(index < 6 ? "nil" : "\(index)")",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 6 of 8 failures read one and the same value (bay.count → nil), across 6 signatures")
    }

    /// A `#require` of an optional reads its whole expression, so a set of them spelled several ways names the `nil` they all came back with.
    @Test
    func aRequiredOptionalsWholeReadIsTheRead() {
        let subjects = ["row", "row", "row", "view", "view", "band", "band", "note"]
        let failures = subjects.enumerated().map { index, subject in
            Self.failure(index, expression: "Gizmo.soleElement(of: \(subject), width: 393)", markedLines: [
                "Gizmo.soleElement(of: \(subject), width: 393) → nil",
                "\(subject) → \(index)",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 8 of 8 failures read one and the same value (Gizmo.soleElement(of: row, width: 393) → nil), across 4 signatures")
    }
}

private extension RunArrowExpansionDominantTests {
    /// Eight properties, so a set of failures is more than the signature cap and each property is a signature of its own.
    static var properties: [String] {
        ["depth", "height", "width", "count", "index", "total", "limit", "level"]
    }

    /// One failed expectation on `expression`, in a file of its own, with the `↳` lines printed beneath it.
    static func failure(_ index: Int, expression: String, markedLines: [String]) -> RunFailureShape.Failure {
        RunFailureShape.Failure(
            name: "aTestNamed\(index)()",
            location: "Sprocket\(index)Tests.swift:\(index + 1):9",
            message: "Expectation failed: \(expression)",
            note: markedLines.joined(separator: " "),
            markedLines: markedLines
        )
    }

    /// The capture's census block with no log left to list into, the form a live answer measures a run this size with.
    static func captureBlock() throws -> [String] {
        let report = try TestSources.runReport("swift-test-nil-reads", invokedAs: ["swift", "test"], exitCode: 1)
        let failures = report.testFailures.map { failure in
            RunFailureShape.Failure(
                name: failure.name,
                location: failure.location,
                message: failure.message,
                arguments: failure.arguments,
                note: failure.note,
                markedLines: failure.markedLines
            )
        }
        var budget = RunFailureCensus.listingBudget
        return RunFailureShape.of(failures, changedFiles: .of([])).rendered(within: 0, spending: &budget)
    }
}
