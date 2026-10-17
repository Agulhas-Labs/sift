//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the scans over Swift Testing's expansion text meeting a raw string literal, whose inner quotes are text and whose brackets and arrows are not structure.
struct RunRawLiteralScanTests {
    /// A `↳` line whose expression holds a raw literal with an inner quote and an arrow splits at the arrow after the literal.
    @Test
    func aMarkerInsideARawLiteralIsNotTheSplit() {
        let failures = (0 ..< 12).map { index in
            let call = index.isMultiple(of: 2) ? "f" : "g"
            let whole = "\(call)(#\"say \"x → y\"#) == \"ok\""
            return Self.failure(index, expression: whole, markedLines: [
                "\(whole) → false",
                "  \(call)(#\"say \"x → y\"#) → nil",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (f(#\"say \"x → y\"#) → nil), across 2 signatures")
    }

    /// An inline expansion holding a raw literal with an inner quote and a closing parenthesis is bounded by its own parentheses.
    @Test
    func aParenthesisInsideARawLiteralIsNotABound() {
        let failures = (0 ..< 12).map { index in
            let comparison = index.isMultiple(of: 2) ? "==" : "!="
            return Self.failure(index, expression: "(f(#\"say \"x) y\"#) → nil) \(comparison) k", markedLines: [])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (f(#\"say \"x) y\"#) → nil), across 2 signatures")
    }

    /// A note's first arrow outside a raw literal is where it merges into the message, though an arrow sits inside the literal before it.
    @Test
    func aMergeSplitsAtTheArrowAfterARawLiteral() {
        let expression = "f(#\"say \"x → y\"#)"

        #expect(RunFailureShape.merging("Expectation failed: \(expression)", with: "\(expression) → nil") == "Expectation failed: \(expression) → nil")
    }

    /// A dot inside a raw literal does not start a member name, so a Boolean read of the text after it is not taken to restate the whole.
    @Test
    func aDotInsideARawLiteralIsNotAMember() {
        let failures = (0 ..< 12).map { index in
            let comparison = index.isMultiple(of: 2) ? "==" : "!="
            return Self.failure(index, expression: "#\"a \"b.c\"# \(comparison) k", markedLines: [
                "#\"a \"b.c\"# \(comparison) k → true",
                "  c\"# \(comparison) k → true",
            ])
        }

        let line = RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line

        #expect(line?.contains("c\"# ") == true)
    }
}

private extension RunRawLiteralScanTests {
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
