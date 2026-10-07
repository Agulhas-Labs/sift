//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the strings tool: value↔key tracing across catalog formats, the literal-site hop, and the honest gaps.
@Suite(.temporaryDirectories)
struct StringCatalogTests {
    private static func makeRepo() throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "dishwasher.finished.left": {
                  "localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "Dishwasher Left finished"}},
                    "fr": {"stringUnit": {"state": "translated", "value": "Lave-vaisselle gauche terminé"}}
                  }
                },
                "items.count": {
                  "localizations": {
                    "en": {"variations": {"plural": {
                      "one": {"stringUnit": {"state": "translated", "value": "One item"}},
                      "other": {"stringUnit": {"state": "translated", "value": "%d items"}}
                    }}}
                  }
                },
                "plain.key": {}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(
            """
            "legacy.key" = "Ancien texte";
            """,
            to: "fr.lproj/Legacy.strings",
            in: root
        )
        try TestSources.write(
            """
            struct Alerts {
                let label = String(localized: "dishwasher.finished.left")
            }
            """,
            to: "Sources/App/Alerts.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "catalog fixture")
        return try SiftEngine(directory: root)
    }

    @Test
    func displayTextFindsItsKeyAcrossLanguagesCaseInsensitively() throws {
        let engine = try Self.makeRepo()

        let byEnglish = try engine.strings(query: "left FINISHED")
        let byFrench = try engine.strings(query: "gauche terminé")

        #expect(byEnglish.contains("dishwasher.finished.left = \"Dishwasher Left finished\""))
        #expect(byEnglish.contains("(2 languages)"))
        // A hit through any language's value still displays the source-language text.
        #expect(byFrench.contains("dishwasher.finished.left = \"Dishwasher Left finished\""))
    }

    @Test
    func aMatchedKeyListsItsLiteralSwiftSites() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "dishwasher.finished.left")

        #expect(output.contains("literal occurrences in Swift source"))
        #expect(output.contains("\"dishwasher.finished.left\": Sources/App/Alerts.swift:2"))
    }

    @Test
    func aKeyWithNoLiteralSitesNamesTheGeneratedAccessorGap() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "items.count")

        // An empty site list must never read as "unused" — the key may live behind a generated accessor.
        #expect(output.contains("\"items.count\": none — likely referenced through a generated accessor"))
    }

    @Test
    func pluralVariationValuesAreSearchable() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "One item")

        #expect(output.contains("items.count"))
    }

    @Test
    func legacyStringsFilesAreSearched() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Ancien")

        #expect(output.contains("fr.lproj/Legacy.strings:"))
        #expect(output.contains("legacy.key = \"Ancien texte\""))
    }

    @Test
    func aRepoWithoutCatalogsSaysSoInsteadOfMatchingNothing() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct S {}", to: "Sources/App/S.swift", in: root)
        try TestSources.commitAll(in: root, message: "no catalogs")
        let engine = try SiftEngine(directory: root)

        let output = try engine.strings(query: "anything")

        #expect(output.contains("no string catalogs (.xcstrings / .strings) in this repo"))
    }

    @Test
    func aMissStatesWhatWasSearched() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "text that appears nowhere")

        #expect(output.contains("no catalog entry matches — searched 2 catalog files"))
    }

    /// The parsed catalog is cached across calls on one engine — the shape a long-lived MCP session's repeated `strings` calls take — but a catalog edited between two calls is never served stale, on the same terms a Swift file's freshness is judged on: an edit changes both the file's size and its mtime, either of which alone is enough to invalidate the cached parse.
    @Test
    func anEditedCatalogIsReflectedOnTheNextQueryEvenAfterAnEarlierQueryCachedIt() throws {
        let engine = try Self.makeRepo()
        let root = engine.repoRoot

        // Cache the parse.
        let before = try engine.strings(query: "dishwasher.finished.left")
        #expect(before.contains("Dishwasher Left finished"))

        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "dishwasher.finished.left": {
                  "localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "Left dishwasher is done"}}
                  }
                }
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )

        let after = try engine.strings(query: "dishwasher.finished.left")

        #expect(after.contains("Left dishwasher is done"))
        #expect(!after.contains("Dishwasher Left finished"))
    }
}
