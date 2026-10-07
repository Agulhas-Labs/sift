//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a catalog key the compiler extracts from an interpolated Swift literal: the answer lists that literal as the key's call site instead of pointing at a generated accessor.
@Suite(.temporaryDirectories)
struct StringsInterpolatedKeyTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "Hello %@": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Hello %@"}}}},
                "%lld items": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld items"}}}},
                "Bye %@ now": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Bye %@ now"}}}}
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
                func hello(name: String) -> String { String(localized: "Hello \(name)") }
                func items(count: Int) -> String { String(localized: "\(count) items") }
                func bye(name: String) -> String { String(localized: "Bye \(name) later") }
            }
            """#,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test(arguments: [
        ("Hello %@", "Sources/App/Depot.swift:2"),
        ("%lld items", "Sources/App/Depot.swift:3"),
    ])
    func anInterpolatedLiteralIsListedAsItsKeysCallSite(key: String, site: String) throws {
        let output = try Self.makeRepo().strings(query: key)

        #expect(output.contains("\"\(key)\": \(site)"), Comment(rawValue: output))
        #expect(!output.contains("none — likely referenced through a generated accessor"), Comment(rawValue: output))
    }

    @Test
    func aLiteralWhoseTextBetweenInterpolationsDiffersIsNotTheKeysCallSite() throws {
        let output = try Self.makeRepo().strings(query: "Bye %@ now")

        #expect(output.contains("\"Bye %@ now\": none"), Comment(rawValue: output))
    }
}
