//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the Booleans a failed expectation implies: the `↳` lines beneath it print `isEmpty → false` and `items.isEmpty → true` as subexpressions, but the failure itself says as much, so they are no read.
struct RunImpliedBooleanReadTests {
    /// The member name that ends the whole expression restates the whole's value, so the receiver's read leads rather than the `false` every failure printed.
    @Test
    func aMemberNameRestatingTheWholeIsNoRead() {
        let dominant = Self.dominantClass { property in
            ("judged(\(property)).isEmpty", [
                "judged(\(property)).isEmpty → false",
                "  judged(\(property)) → unset",
                "  isEmpty → false",
            ])
        }

        #expect(dominant?.value == "unset")
        #expect(dominant?.count == Self.properties.count)
    }

    /// Under a leading `!`, the stripped expression and its member name carry the implied opposite value, so the receiver's read leads rather than the `true` every failure printed.
    @Test
    func aNegatedExpressionAndItsMemberAreNoRead() {
        let dominant = Self.dominantClass { property in
            ("!\(property).isEmpty", [
                "!\(property).isEmpty → false",
                "  \(property).isEmpty → true",
                "    \(property) → unset",
                "    isEmpty → true",
            ])
        }

        #expect(dominant?.value == "unset")
        #expect(dominant?.count == Self.properties.count)
    }

    /// A Boolean read of an operand of a conjunction can be the cause the failures share, so it stays a read.
    @Test
    func aBooleanOperandOfAConjunctionStaysARead() {
        let dominant = Self.dominantClass { property in
            ("\(property) && other", [
                "\(property) && other → false",
                "  \(property) → false",
                "  other → unset",
            ])
        }

        #expect(dominant?.value == "false")
        #expect(dominant?.count == Self.properties.count)
    }

    /// A Boolean property of a different expression is a read even where its name is not the whole's last member.
    @Test
    func aBooleanPropertyOfAnotherExpressionStaysARead() {
        let dominant = Self.dominantClass { property in
            ("\(property).isReady == other", [
                "\(property).isReady == other → false",
                "  \(property).isReady → false",
                "  other → unset",
            ])
        }

        #expect(dominant?.value == "false")
        #expect(dominant?.count == Self.properties.count)
    }

    /// Eight properties, so a set of failures is more than the signature cap and each property is a signature of its own.
    private static var properties: [String] {
        ["depth", "height", "width", "count", "index", "total", "limit", "level"]
    }

    /// The dominant class of one failed expectation per property, each printing the `↳` lines `shape` gives for it.
    private static func dominantClass(_ shape: (String) -> (expression: String, lines: [String])) -> RunDominantFailureClass? {
        let failures = properties.enumerated().map { index, property in
            let printed = shape(property)
            return RunFailureShape.Failure(
                name: "aTestNamed\(index)()",
                location: "Sprocket\(index)Tests.swift:\(index + 1):9",
                message: "Expectation failed: \(printed.expression)",
                note: printed.lines.joined(separator: " "),
                markedLines: printed.lines
            )
        }
        return RunFailureShape.of(failures, changedFiles: .of([])).dominantClass
    }
}
