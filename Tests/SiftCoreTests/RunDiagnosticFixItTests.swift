//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// SwiftPM 6.4 appends each compiler fix-it to its message as a Swift struct dump; the answer carries the diagnostic without it.
struct RunDiagnosticFixItTests {
    /// The captured build names the error at its own location and says what was expected, and no part of the dump reaches the answer.
    @Test
    func aFixItDumpIsCutFromTheCapturedDiagnostic() throws {
        let report = try TestSources.runReport("swift-build-fixit-6.4", invokedAs: ["swift", "build"], exitCode: 1)

        let error = try #require(report.errors.first)

        #expect(report.errors.count == 1)
        #expect(error.message == "expected 'func' keyword in instance method declaration")
        #expect(error.path == "/Users/dev/Widget/Sources/Widget/Widget.swift")
        #expect(error.line == 6)
        #expect(error.column == 5)
        #expect(!error.compilerLine.contains("FixIt("))
        #expect(error.compilerLine.hasSuffix("error: expected 'func' keyword in instance method declaration"))
    }

    /// A message that opens like a dump but does not close one at the end of the line keeps every word of it.
    @Test
    func aMessageThatDoesNotCloseADumpKeepsItsText() throws {
        let raw = "/src/Widget.swift:3:1: error: unterminated literal: FixIt(sourceRange: was never closed"
        let diagnostic = try #require(RunDiagnostic.parse(raw))

        #expect(diagnostic.message == "unterminated literal: FixIt(sourceRange: was never closed")
    }

    /// An XCTest failure quoting text that opens like a dump is not a dump: the whole assertion reaches the answer.
    @Test
    func anXCTestFailureQuotingAFixItKeepsItsText() throws {
        let raw = #"/src/WidgetTests.swift:12: error: -[WidgetTests testA] : XCTAssertEqual failed: ("note: FixIt(sourceRange: here)") is not equal to ("other")"#
        let diagnostic = try #require(RunDiagnostic.parse(raw))

        #expect(diagnostic.message.hasSuffix(#"XCTAssertEqual failed: ("note: FixIt(sourceRange: here)") is not equal to ("other")"#))
    }
}
