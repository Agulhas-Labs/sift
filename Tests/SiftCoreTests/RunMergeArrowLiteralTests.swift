//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An expectation whose expression holds a string literal with an arrow still has its evaluation merged into its message, because the expression ends at the first arrow no literal holds.
struct RunMergeArrowLiteralTests {
    @Test
    func anArrowInsideALiteralDoesNotEndTheExpression() {
        let merged = RunFailureShape.merging("Expectation failed: label == \"a → b\"", with: "label == \"a → b\" → false")

        #expect(merged == "Expectation failed: label == \"a → b\" → false")
    }

    @Test
    func anEscapedQuoteDoesNotCloseTheLiteralEarly() {
        let merged = RunFailureShape.merging("Expectation failed: x == \"say \\\"a → b\\\"\"", with: "x == \"say \\\"a → b\\\"\" → false")

        #expect(merged == "Expectation failed: x == \"say \\\"a → b\\\"\" → false")
    }

    @Test
    func anArrowOutsideAnyLiteralMergesAsBefore() {
        #expect(RunFailureShape.merging("Expectation failed: count", with: "count → 3") == "Expectation failed: count → 3")
        #expect(RunFailureShape.merging("Expectation failed: count", with: "other → 3") == nil)
    }

    @Test
    func aRenderedFailureWithALiteralArrowCarriesNoAdjacencyMarker() {
        let failure = RunFailureShape.Failure(
            name: "aTest()",
            location: "WidgetTests.swift:3:9",
            message: "Expectation failed: label == \"a → b\"",
            note: "label == \"a → b\" → false"
        )
        let lines = RunFailureShape.of([failure], changedFiles: .of([])).rendered()

        #expect(lines.contains { $0.contains("label == \"a → b\" → false") })
        #expect(!lines.contains { $0.contains("(by adjacency)") })
    }
}
