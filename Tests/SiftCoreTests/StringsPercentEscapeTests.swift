//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a literal percent sign in a catalog key: `%%` is one `%` of text, and a `%` followed by a space is not a specifier.
@Suite(.temporaryDirectories)
struct StringsPercentEscapeTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "%lld%% done": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld%% done"}}}},
                "50% off": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "50% off"}}}}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(
            #"""
            struct Depot {
                func progress(n: Int) -> String { String(localized: "\(n)% done") }
                func sale() -> String { String(localized: "50% off") }
                func decoy(x: Int) -> String { String(localized: "50\(x)ff") }
            }
            """#,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test
    func aDoublePercentInAKeyMatchesTheLiteralPercentOfAnInterpolatedLiteral() throws {
        let output = try Self.makeRepo().strings(query: "%lld%% done")

        #expect(output.contains("\"%lld%% done\": Sources/App/Depot.swift:2"), Comment(rawValue: output))
        #expect(!output.contains("none — likely referenced"), Comment(rawValue: output))
    }

    @Test
    func aPercentBeforeASpaceDoesNotMakeAPlainKeyAFormatKey() throws {
        let output = try Self.makeRepo().strings(query: "50% off")

        #expect(output.contains("\"50% off\": Sources/App/Depot.swift:3"), Comment(rawValue: output))
        #expect(!output.contains("Depot.swift:4"), Comment(rawValue: output))
    }
}
