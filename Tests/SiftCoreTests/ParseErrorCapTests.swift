//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers ``FileParser/listedCap``: past it a file's errors are counted by ``ParseErrorTally`` and listed as one, because wording each one takes the diagnostics generator time that grows with the square of their number, minutes for a generated file of a few thousand.
@Suite(.temporaryDirectories)
struct ParseErrorCapTests {
    /// A run of trailing closures with nothing to trail, two errors to each `unit`, all on one line: the shape the generator is slowest on.
    private static func strayClosures(_ units: Int) -> String {
        String(repeating: "f {} {} {} ", count: units)
    }

    private static func tally(_ source: String) -> Int {
        ParseThread.parse(source) { ParseErrorTally(walking: $0).count }
    }

    @Test
    func aFileWithMoreErrorsThanTheCapIsCountedInOneWalkAndListedAsOneError() throws {
        let source = Self.strayClosures(200)
        let count = Self.tally(source)
        #expect(count > FileParser.listedCap)

        let errors = FileParser.errors(inSource: source, path: "Generated.swift")
        let parsed = try TestSources.parsed(source, path: "Sources/App/Generated.swift")

        #expect(errors.map(\.message) == [FileParser.tooManyMessage(count: count)])
        #expect(errors.first?.line == 1)
        #expect(parsed.parseErrorCount == count)
    }

    @Test
    func aFileWithinTheCapHasEachErrorWordedByTheParser() throws {
        let source = Self.strayClosures(20)
        let count = Self.tally(source)
        #expect(count <= FileParser.listedCap)

        let errors = FileParser.errors(inSource: source, path: "Generated.swift")
        let parsed = try TestSources.parsed(source, path: "Sources/App/Generated.swift")

        #expect(errors.count == count)
        #expect(!errors.contains { $0.message == FileParser.tooManyMessage(count: count) })
        #expect(parsed.parseErrorCount == errors.count)
    }
}
