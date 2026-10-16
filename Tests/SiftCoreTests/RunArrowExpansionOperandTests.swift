//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the operands Swift Testing expands beside the values a failure read: the expected side of a comparison, `some → "ok"`, `Optional("ok") → "ok"`, `.none → nil`, restates what the test expected, never what the code returned.
struct RunArrowExpansionOperandTests {
    /// Every failure compared a nil read against one literal, and the line names the nil read rather than the literal Swift Testing expanded as `some`.
    @Test
    func theExpectedLiteralIsNeverTheValueRead() {
        let failures = (0 ..< 12).map { index in
            let call = index.isMultiple(of: 2) ? "c(i)" : "d(i)"
            return Self.failure(index, expression: "\(call) == \"ok\"", markedLines: [
                "\(call) == \"ok\" → false",
                "\(call) → nil",
                "some → \"ok\"",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (c(i) → nil), across 2 signatures")
    }

    /// Failures that read different values against one literal operand share nothing they read.
    ///
    /// A unit case rather than evidence of real output: Swift 6.4 prints no expansion of its own for a plain non-optional literal (`-7` printed none), so `3 → 3` is the shape a literal would take were it expanded.
    @Test
    func aLiteralOperandIsNotAValueRead() {
        let failures = (0 ..< 8).map { index in
            let call = index.isMultiple(of: 2) ? "e(i)" : "f(i)"
            return Self.failure(index, expression: "\(call) == 3", markedLines: [
                "\(call) == 3 → false",
                "\(call) → \(index + 10)",
                "3 → 3",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass == nil)
    }

    /// Each expected operand a real Swift 6.4 run expanded beside reads that differ every time leaves no value most failures read: the operand restates what the test wrote.
    @Test(arguments: [
        ("Optional(\"ok\")", "\"ok\""),
        ("#\"ok\"#", "\"ok\""),
        ("1.0e3", "1000.0"),
        (".none", "nil"),
        (".some(\"ok\")", "\"ok\""),
    ])
    func anExpectedOperandIsNotTheValueRead(operand: String, expanded: String) {
        let failures = (0 ..< 12).map { index in
            let call = index.isMultiple(of: 2) ? "a(i)" : "b(i)"
            return Self.failure(index, expression: "\(call) == \(operand)", markedLines: [
                "\(call) == \(operand) → false",
                "\(call) → .shade\(index)",
                "\(operand) → \(expanded)",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass == nil)
    }

    /// Failures that all read nil beside an expected operand expanded to `"ok"` lead with the nil read, not the operand.
    @Test
    func aNilReadBesideAnExpectedOperandIsNamed() {
        let failures = (0 ..< 12).map { index in
            let (call, operand) = index.isMultiple(of: 2) ? ("a(i)", "Optional(\"ok\")") : ("b(i)", "#\"ok\"#")
            return Self.failure(index, expression: "\(call) == \(operand)", markedLines: [
                "\(call) == \(operand) → false",
                "\(call) → nil",
                "\(operand) → \"ok\"",
            ])
        }

        #expect(RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line == "  ↳ 12 of 12 failures read one and the same value (a(i) → nil), across 2 signatures")
    }

    /// An expression restates an operand only where it names nothing but literal syntax: string literals without an interpolation, numeric literals in any Swift spelling, `true`, `false`, `nil`, `some`, `none`, `Optional`, implicit members with no receiver, and the operators and brackets between them.
    ///
    /// Any other identifier, an interpolation or an explicit type member is a read.
    @Test(arguments: [
        ("some", true), ("none", true), ("nil", true), ("true", true), ("false", true),
        ("\"ok\"", true), ("\"say \\\"hi\\\"\"", true), ("#\"ok\"#", true), ("##\"a\"#b\"##", true), ("#\"\\(x)\"#", true), ("\"\"\"\nok\n\"\"\"", true),
        ("-3.5", true), ("1.0e3", true), ("1e-3", true), ("0x1F", true), ("0x1.8p3", true), ("0o17", true), ("0b1010", true), ("1_000", true),
        (".some(\"ok\")", true), ("Optional(3)", true), ("Optional(\"ok\")", true), ("\"a\" + \"b\"", true), ("[1, 2]", true),
        (".none", true), (".blue", true), (".zero", true),
        ("\"v\\(i)\"", false), ("#\"v\\#(i)\"#", false), ("count", false), ("x1", false), ("-x", false), ("expected", false), ("a.b", false),
        ("c(3)", false), (".some(x)", false), ("Optional(value)", false), ("Color.blue", false), ("Config.current", false), ("1...n", false),
    ])
    func onlyAWholeLiteralRestatesAnOperand(expression: String, restates: Bool) {
        #expect(RunDominantFailureClass.restatesAnOperand(expression) == restates)
    }
}

private extension RunArrowExpansionOperandTests {
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
