//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a catalog key made only of specifiers (Xcode's key for `Text("\(x)")`): it carries no text to match, so no bare interpolation is its call site.
@Suite(.temporaryDirectories)
struct StringsBareSpecifierKeyTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "%@": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%@"}}}},
                "%lld": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "%lld"}}}}
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
                func first(x: String) -> String { "\(x)" }
                func second(x: Int) -> String { "\(x)" }
            }
            """#,
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test(arguments: ["%@", "%lld"])
    func aBareInterpolationIsNotACallSiteOfAKeyMadeOfSpecifiers(key: String) throws {
        let output = try Self.makeRepo().strings(query: key)

        #expect(output.contains("\"\(key)\": none"), Comment(rawValue: output))
        #expect(!output.contains("\"\(key)\": Sources/App/Depot.swift"), Comment(rawValue: output))
    }
}
