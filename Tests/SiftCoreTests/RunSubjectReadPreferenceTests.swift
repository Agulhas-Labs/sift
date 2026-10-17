//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which value the dominant-class line leads with when several are read by more than half the failures: the one read as the failure's subject, ahead of a constant on the expected side.
struct RunSubjectReadPreferenceTests {
    /// A subject read by most failures leads over an expected constant read by all of them.
    @Test
    func aSharedSubjectReadOutranksAConstantReadByEveryFailure() {
        let failures = (0 ..< 12).map { index in
            let subject = index.isMultiple(of: 2) ? "rows" : "items"
            let value = index < 8 ? "\"\"" : "\"r\(index)\""
            return Self.failure(index, expression: "\(subject) == expected", markedLines: [
                "\(subject) == expected → false",
                "  \(subject) → \(value)",
                "  expected → \"q\"",
            ])
        }

        #expect(Self.line(failures) == "  ↳ 8 of 12 failures read one and the same value (items → \"\"), across 2 signatures")
    }

    /// With every failure reading the same subject and the same constant, the subject leads, not the text order.
    @Test
    func aTiedSubjectBeatsAConstantOnText() {
        let failures = (0 ..< 12).map { index in
            let subject = index.isMultiple(of: 2) ? "rows" : "items"
            return Self.failure(index, expression: "\(subject) == expected", markedLines: [
                "\(subject) == expected → false",
                "  \(subject) → \"z\"",
                "  expected → \"a\"",
            ])
        }

        #expect(Self.line(failures) == "  ↳ 12 of 12 failures read one and the same value (items → \"z\"), across 2 signatures")
    }

    /// The known limit: a constant that is the only value past the half still leads, since its text cannot tell it from a read.
    ///
    /// This passes without the preference as well.
    @Test
    func aConstantThatIsTheOnlyValuePastTheHalfStillLeads() {
        let failures = (0 ..< 12).map { index in
            let subject = index.isMultiple(of: 2) ? "rows" : "items"
            return Self.failure(index, expression: "\(subject) == expected", markedLines: [
                "\(subject) == expected → false",
                "  \(subject) → \"r\(index)\"",
                "  expected → \"q\"",
            ])
        }

        #expect(Self.line(failures) == "  ↳ 12 of 12 failures read one and the same value (expected → \"q\"), across 2 signatures")
    }

    /// A subject confined to one signature does not displace a value spread over two, which the spread guard would otherwise have dropped.
    @Test
    func aSubjectInOneSignatureDoesNotHideASpreadValue() {
        let failures = (0 ..< 8).map { index in
            let call = index < 6 ? "lookup" : "fetch"
            let inner = index < 6 ? "  lookup(shared) → nil" : "  fetch(shared) → \"x\(index)\""
            return Self.failure(index, expression: "\(call)(shared) == \"ok\"", markedLines: [
                "\(call)(shared) == \"ok\" → false",
                inner,
                "    shared → \"cfg\"",
            ])
        }

        #expect(Self.line(failures) == "  ↳ 8 of 8 failures read one and the same value (shared → \"cfg\"), across 2 signatures")
    }

    /// A subject spread over two signatures still outranks a constant spread over the same two.
    @Test
    func aSpreadSubjectStillOutranksASpreadConstant() {
        let failures = (0 ..< 8).map { index in
            let subject = index.isMultiple(of: 2) ? "rows" : "items"
            return Self.failure(index, expression: "\(subject) == expected", markedLines: [
                "\(subject) == expected → false",
                "  \(subject) → \"s\"",
                "  expected → \"q\"",
            ])
        }

        #expect(Self.line(failures) == "  ↳ 8 of 8 failures read one and the same value (items → \"s\"), across 2 signatures")
    }
}

private extension RunSubjectReadPreferenceTests {
    /// The dominant-class line of `failures`, if any.
    static func line(_ failures: [RunFailureShape.Failure]) -> String? {
        RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line
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
}
