//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `Self (size: 7)` with a space or a tab before the parenthesis compiles as a call (a line break there does not), so a file spelling it and neither an asked type nor `init` is parsed for an initializer sweep too.
@Suite(.temporaryDirectories)
struct SyntacticCallerSpacedSelfCallTests {
    @Test
    func aSelfCallWithASpaceOrATabBeforeItsParenthesisIsCounted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(SyntacticCallerSelfCallTests.box, to: "Sources/App/Box.swift", in: root)
        try TestSources.write("extension Maker {\n    static func make() -> Self { Self (size: 7) }\n}\n", to: "Sources/App/Maker.swift", in: root)
        try TestSources.write("extension Maker {\n    static func spare() -> Self {\n        Self\t(size: 8)\n    }\n}\n", to: "Sources/App/Spare.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)

        #expect(output.contains("but Self(…) in an extension is called 2 times with those labels on a type the scan cannot tell"), "\(output)")
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output)
        #expect(rows.contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(output)")
        #expect(rows.contains("  Sources/App/Spare.swift:3  in Maker.spare()"), "\(output)")
    }

    @Test
    func theMatcherReadsSpacesAndLineBreaksBetweenSelfAndItsParenthesis() {
        #expect(SelfCallSpelling.isWritten(in: "x = Self(size: 1)"))
        #expect(SelfCallSpelling.isWritten(in: "x = Self \t(size: 1)"))
        #expect(SelfCallSpelling.isWritten(in: "x = Self\r\n  (size: 1)"))
        #expect(!SelfCallSpelling.isWritten(in: "x = Self.make(size: 1)"))
        #expect(!SelfCallSpelling.isWritten(in: "func f() -> Self { self }"))
    }
}
