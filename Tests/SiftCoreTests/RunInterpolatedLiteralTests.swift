//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a string literal whose interpolation holds a literal of its own: the body belongs to the outer literal, so a quote, an arrow or a parenthesis inside it is never structure.
struct RunInterpolatedLiteralTests {
    /// The expression a whole line names keeps its interpolated nested literal, so the line cut at its arrow is the whole expression and the expansion beneath it matches.
    @Test
    func aQuoteInsideAnInterpolationDoesNotCutTheExpression() {
        let expression = "f(\"\\(g(\"a → b\"))\")"
        let failures = (0 ..< 12).map { index in
            let call = index.isMultiple(of: 2) ? expression : "h(\"\\(g(\"a → b\"))\")"
            return Self.failure(index, expression: "\(call) == \"ok\"", markedLines: [
                "\(call) == \"ok\" → false",
                "  \(call) → nil",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (\(expression) → nil), across 2 signatures")
    }

    /// A note whose first arrow sits inside an interpolation's nested literal merges on the arrow after the expression.
    @Test
    func anArrowInsideAnInterpolatedLiteralIsNotTheNotesArrow() {
        let expression = "f(\"\\(g(\"a → b\"))\")"

        #expect(RunFailureShape.merging("Expectation failed: \(expression)", with: "\(expression) → nil") == "Expectation failed: \(expression) → nil")
    }

    /// An interpolation is a read, whatever literal it holds.
    ///
    /// This passes without the interpolation skip too: the literal's extent never decided it.
    @Test
    func anInterpolatedNestedLiteralIsAReadNotARestatement() {
        #expect(!RunDominantFailureClass.restatesAnOperand("\"\\(f(\"x\"))\""))
    }
}

private extension RunInterpolatedLiteralTests {
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
}
