//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a strings answer following a key no literal spells to the accessor its last component names, in the same answer.
@Suite(.temporaryDirectories)
struct StringsAccessorFollowTests {
    /// A repo whose catalog holds a key reached through an enum case, a key spelled as a literal, and a key whose accessor nothing declares.
    private static func makeRepo(extraUses: Int = 0) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            {
              "sourceLanguage": "en",
              "strings": {
                "Strings.greeting": {
                  "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Welcome aboard"}}}
                },
                "lobby.title": {
                  "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Lobby heading"}}}
                },
                "lobby.missing": {
                  "localizations": {"en": {"stringUnit": {"state": "translated", "value": "Lobby absent"}}}
                },
                "Tap to begin": {},
                "tile.alpha": {},
                "tile.beta": {},
                "tile.delta": {},
                "tile.gamma": {}
              },
              "version": "1.0"
            }
            """,
            to: "Resources/Localizable.xcstrings",
            in: root
        )
        try TestSources.write(
            """
            enum Strings: String {
                case greeting
                case farewell
            }
            """,
            to: "Sources/App/Strings.swift",
            in: root
        )
        try TestSources.write(
            "let long = Strings.greeting // " + String(repeating: "x", count: 200) + "\n",
            to: "Sources/App/Banner.swift",
            in: root
        )
        let extra = (0 ..< extraUses).map { "        _ = Strings.greeting // \($0)" }.joined(separator: "\n")
        try TestSources.write(
            """
            struct Lobby {
                let title = String(localized: "lobby.title")

                func banner() -> Strings {
                    let chosen   =    Strings.greeting
            \(extra)
                    return chosen
                }
            }
            """,
            to: "Sources/App/Lobby.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "accessor fixture")
        return try SiftEngine(directory: root)
    }

    /// The answer below its live header line, which names a temporary directory.
    private static func body(_ answer: String) -> String {
        answer.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
    }

    @Test
    func aKeyNoLiteralSpellsIsFollowedToItsAccessorsDeclarationAndUseSite() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Welcome aboard")

        #expect(output.contains("  \"Strings.greeting\": none — likely referenced through a generated accessor (a Strings enum, an R-type)\n"))
        #expect(output.contains("    accessor \"greeting\" — matched by written name over the working tree, so a same-named symbol elsewhere may be listed:"))
        #expect(output.contains("      declared: case Strings.greeting — Sources/App/Strings.swift:2"))
        // The use site names its path, line, enclosing declaration and its line's text with the whitespace collapsed.
        #expect(output.contains("      Sources/App/Lobby.swift:5 in Lobby.banner().chosen: let chosen = Strings.greeting"))
        #expect(!output.contains("use where/search on the generated symbol"))
    }

    @Test
    func aKeyWithALiteralOccurrenceRendersAsBefore() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Lobby heading")

        #expect(Self.body(output) == """
        strings "Lobby heading"
        1 key in 1 catalog — searched 1 catalog file; working-tree read, never stale

        Resources/Localizable.xcstrings:
          lobby.title = "Lobby heading"

        literal occurrences in Swift source (keys spelled as string literals — String(localized:)/NSLocalizedString style):
          "lobby.title": Sources/App/Lobby.swift:2
        """)
    }

    @Test
    func anAccessorTheTreeNeitherDeclaresNorWritesKeepsOneShortLine() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Lobby absent")

        #expect(output.contains("  \"lobby.missing\": none — likely referenced through a generated accessor (a Strings enum, an R-type); no Swift file declares or writes \"missing\""))
        #expect(!output.contains("accessor \"missing\""))
    }

    @Test
    func useSitesPastTheCapAreCountedAndPointAtWhere() throws {
        let engine = try Self.makeRepo(extraUses: 11)

        let output = try engine.strings(query: "Welcome aboard")

        #expect(output.contains("      +1 more sites — where greeting lists them all"))
    }

    @Test
    func aSitesLongLineIsCutAtTheCapWithAnEllipsis() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Welcome aboard")

        // The line runs to 231 characters; the shown text stops at 140, the comment's 109th character.
        #expect(output.contains(": let long = Strings.greeting // " + String(repeating: "x", count: 109) + "…"))
    }

    @Test
    func onlyTheFirstThreeKeysAreFollowedAndTheRestKeepTheAdvice() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "tile.")

        #expect(output.contains("  \"tile.alpha\": none — likely referenced through a generated accessor (a Strings enum, an R-type); no Swift file declares or writes \"alpha\""))
        #expect(output.contains("  \"tile.beta\": none — likely referenced through a generated accessor (a Strings enum, an R-type); no Swift file declares or writes \"beta\""))
        #expect(output.contains("  \"tile.delta\": none — likely referenced through a generated accessor (a Strings enum, an R-type); no Swift file declares or writes \"delta\""))
        #expect(output.contains("  \"tile.gamma\": none — likely referenced through a generated accessor (a Strings enum, an R-type); use where/search on the generated symbol"))
    }

    @Test
    func aKeyWhoseLastComponentIsNoIdentifierKeepsTheAdvice() throws {
        let engine = try Self.makeRepo()

        let output = try engine.strings(query: "Tap to begin")

        #expect(output.contains("  \"Tap to begin\": none — likely referenced through a generated accessor (a Strings enum, an R-type); use where/search on the generated symbol"))
        #expect(!output.contains("accessor \""))
    }
}
