//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers every strings line that prints a key writing it escaped, so a newline or a quote in a key cannot split its line or end its quotes early.
@Suite(.temporaryDirectories)
struct StringsKeyEscapeTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "two\\nlines %@": {},
                "two\\nlines.title": {},
                "Say \\"hi\\"": {}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(
            ##"""
            struct Depot {
                func say() -> String { String(localized: #"Say "hi""#) }
            }
            """##,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test(arguments: [
        ("two\nlines %@", #"  "two\nlines %@": none — likely referenced"#),
        ("two\nlines.title", #"  "two\nlines.title": none — likely referenced"#),
    ])
    func aKeyWithANewlineIsOneLineWhereTheLiteralOccurrencesPrintIt(query: String, line: String) throws {
        let output = try Self.makeRepo().strings(query: query)

        #expect(output.split(separator: "\n").contains { $0.hasPrefix(line) }, Comment(rawValue: output))
        #expect(!output.contains("\"two\nlines"), Comment(rawValue: output))
    }

    @Test
    func aKeyWithQuotesIsEscapedOnItsSiteLine() throws {
        let output = try Self.makeRepo().strings(query: #"Say "hi""#)

        #expect(output.split(separator: "\n").contains { $0.hasPrefix(#"  "Say \"hi\"": Sources/App/Depot.swift:2"#) }, Comment(rawValue: output))
    }
}
