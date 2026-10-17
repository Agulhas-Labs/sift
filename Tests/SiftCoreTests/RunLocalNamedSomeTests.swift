//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a local named `some` or `none`: where the expectation writes the word bare, its expansion is the local's read, not the wrapper Swift Testing labels an Optional's payload with.
struct RunLocalNamedSomeTests {
    /// Every failure read a nil from a local named `some`, and the line names it, while the payload read beneath it restates the expected literal and stays set aside.
    @Test
    func aLocalNamedSomeKeepsItsRead() {
        let failures = (0 ..< 12).map { index in
            let (literal, value) = index.isMultiple(of: 2) ? ("\"ok\"", "\"ok\"") : ("label(\"go\")", "\"go\"")
            return Self.failure(index, expression: "some == \(literal)", markedLines: [
                "some == \(literal) → false",
                "  some → nil",
                "    some → \(value)",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (some → nil), across 2 signatures")
    }

    /// The same holds for a local named `none`.
    @Test
    func aLocalNamedNoneKeepsItsRead() {
        let failures = (0 ..< 12).map { index in
            let literal = index.isMultiple(of: 2) ? "3" : "limit"
            return Self.failure(index, expression: "none == \(literal)", markedLines: [
                "none == \(literal) → false",
                "  none → nil",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (none → nil), across 2 signatures")
    }

    /// The word counts as written only bare: inside a string literal or straight after a `.` it is no local, and the expansion stays a restated operand.
    @Test(arguments: [
        (".some(\"ok\")", "\"ok\"", "a(i) == .some(\"ok\")", true),
        ("Optional(\"ok\")", "\"ok\"", "a(i) == Optional(\"ok\")", true),
        ("some", "\"ok\"", "a(i) == .some(\"ok\")", true),
        ("some", "\"ok\"", "a(i) == \"some\"", true),
        ("some", "\"ok\"", "a(i) == #\"some\"#", true),
        ("some", "\"ok\"", "someone(i) == \"ok\"", true),
        ("none", "nil", "a(i) == .none", true),
        ("some", "\"ok\"", "some == \"ok\"", true),
        ("some", "nil", "some == \"ok\"", false),
        ("some", "\"v0\"", "some == \"ok\"", false),
        ("none", "nil", "none == 3", false),
        ("Optional", "\"ok\"", "Optional == \"ok\"", true),
        ("some", "1000", "f(some: k) == 1_000", true),
        ("some", "7", "c ? some : 0", false),
    ])
    func theWordMustBeWrittenBare(expression: String, value: String, source: String, restates: Bool) {
        #expect(RunDominantFailureClass.restatesAnOperand(expression, reading: value, writtenIn: source) == restates)
    }
}

extension RunLocalNamedSomeTests {
    /// An argument label `some:` is no local, so the Optional wrapper beside a literal the expectation wrote prints no line.
    @Test
    func anArgumentLabelNamedSomeIsNoRead() {
        let failures = (0 ..< 8).map { index in
            let call = index.isMultiple(of: 2) ? "lookup" : "fetch"
            return Self.failure(index, expression: "\(call)(some: key) == 1_000", markedLines: [
                "\(call)(some: key) == 1_000 → false",
                "  \(call)(some: key) → \(index)",
                "    some → 1000",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass == nil)
    }

    /// A value that is only a substring of another literal in the expectation is still the local's read.
    @Test
    func aValueInsideAnotherLiteralIsStillARead() {
        let failures = (0 ..< 8).map { index in
            let comparison = index.isMultiple(of: 2) ? "some == 10" : "some >= 10"
            return Self.failure(index, expression: comparison, markedLines: [
                "\(comparison) → false",
                "  some → 1",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 8 of 8 failures read one and the same value (some → 1), across 2 signatures")
    }
}

private extension RunLocalNamedSomeTests {
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
