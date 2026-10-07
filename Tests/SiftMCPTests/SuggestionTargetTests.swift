//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Every call a refusal offers is one the tool can be asked: its target a name, a dotted path, the overview, a Swift file's own name, or a `search` query — never what a pattern left behind.
struct SuggestionTargetTests {
    private static func call(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(ShellAdvice.suggestion(for: command), sourceLocation: sourceLocation).call
    }

    /// What a regex leaves behind is never a target.
    ///
    /// A pattern that reaches a file's slot — an operand after `-e` gave the pattern away, or a regex quoted as the path — leaves a stem like `[A-Za-z0-9_]+\`, and a call carrying one is a call nobody can make: the refusal costs a round trip and says nothing. So every target is held to what its tool accepts, and a lookup left with none offers no call, which the hook withholds and the scan scores out of the share, as it does every untargeted one.
    @Test
    func aRegexIsNeverATarget() throws {
        for command in [#"cat '[A-Za-z0-9_]+\.swift'"#, #"grep -oE -e 'x' '[A-Za-z0-9_]+\.swift'"#] {
            let suggestion = try #require(ShellAdvice.suggestion(for: command))
            #expect(!suggestion.namesATarget, "\(command)")
            #expect(!suggestion.call.contains("["), "\(command)")
        }
        // A name beside the residue is still the lookup, asked without the file it cannot be asked through.
        #expect(try Self.call(#"grep -n signedDelta '[A-Za-z0-9_]+\.swift'"#) == "where signedDelta")
        #expect(try !#require(ShellAdvice.suggestion(for: #"grep -rn '[A-Za-z0-9_]+\\' Sources --include=*.swift"#)).namesATarget)

        // Held where every surface builds its call, and on every builder.
        #expect(!IndexSuggestion.forLookup(symbol: #"[A-Za-z0-9_]+\"#, file: nil).namesATarget)
        #expect(IndexSuggestion.forNames(["UsageWindow", "[A-Z]+"]).call == "where UsageWindow")
        #expect(!IndexSuggestion.forNames(["[A-Z]+", #"\w+"#]).namesATarget)
        #expect(IndexSuggestion.forFiles(["Sources/App/View.swift", #"[a-z]+\.swift"#]).call == "digest View")
        #expect(!IndexSuggestion.forFiles([#"[a-z]+\.swift"#, #"(a|b)\.swift"#]).namesATarget)
        #expect(IndexSuggestion.forGlob("Sources/[A-Z]+/*.swift").call == "digest .")
        #expect(ReadAdvice.suggestion(path: #"/x/[A-Za-z0-9_]+\.swift"#, ranged: false, belowFloor: { _ in false }) == nil)

        // And the property both ends ask, over every shape a residue has taken and every one a target has.
        let uncallable = [
            #"digest [A-Za-z0-9_]+\"#, "digest *", "digest *.Split", "digest **", "digest .Split", "digest Split.",
            "digest", "where [A-Z]+", #"where UsageWindow\|UsageLog"#, "search", "search name:[a-z]+",
            "where UsageWindow\nwhere [A-Z]+",
        ]
        for call in uncallable {
            #expect(!IndexSuggestion(call: call, yields: "").namesATarget, "\(call)")
        }
        let callable = [
            "digest .", "digest UsageLog", "digest Outer.Nested.member", "digest Lantern+Extras.swift", "where id",
            "search kind:class name:Store", "search attr:Observable !has:await", "where UsageWindow\nwhere UsageLog",
            "digest Café", "where Über.größe", "digest Sources/App/Foo Bar.swift", "digest /x/Sources/App/Foo Bar.swift",
        ]
        for call in callable {
            #expect(IndexSuggestion(call: call, yields: "").namesATarget, "\(call)")
        }
    }

    /// A file whose stem is not a name is digested by its own name, which `digest` resolves as the file.
    ///
    /// `Lantern+Extras` names no symbol, so a call asking for it by stem answers "no symbol named" — a refusal whose one suggestion fails. A member of it has no stem to be asked through, so the name alone is the lookup.
    @Test
    func aFileWhoseStemIsNoNameIsDigestedByItsName() throws {
        #expect(try Self.call("cat Sources/Lib/Lantern+Extras.swift") == "digest Lantern+Extras.swift")
        #expect(try Self.call("grep -n brightness Sources/Lib/Lantern+Extras.swift") == "where brightness")
        let read = ReadAdvice.suggestion(path: "/x/Sources/Lib/Lantern+Extras.swift", ranged: false, belowFloor: { _ in false })
        #expect(read?.call == "digest Lantern+Extras.swift")
        #expect(read?.namesATarget == true)
    }

    /// A file's name is text written about a file, never a symbol: a sweep for one asks for a comment, a string literal or a document line, which the index does not record.
    ///
    /// Read as a dotted path, `rules/sift.md` stands on the name `sift` and a member `md`, so an alternation of paths was refused with `where sift`, which nobody asked for.
    @Test
    func aSweepForAFilesNameStandsOnNoSymbol() throws {
        let paths = try #require(ShellAdvice.suggestion(for: #"grep -rn "rules/sift.md\|docs/sift.md" Sources --include=*.swift"#))

        #expect(paths.call == "search")
        #expect(!paths.namesATarget)
        #expect(try Self.call(#"grep -rn "UsageWindow.swift" Sources --include=*.swift"#) == "search")
        #expect(try Self.call(#"grep -rn "Sources/App/UsageWindow" Sources --include=*.swift"#) == "search")
        #expect(SweepPattern.reading(of: #"rules/sift\.md\b"#) == .text)
        #expect(PatternReading.identifier(in: "rules/sift.md") == nil)
        // A member that happens to share a data file's extension is still a member, and a comment marker is not a path.
        #expect(try Self.call(#"grep -rn "Depot.json" Sources --include=*.swift"#) == "where Depot")
        #expect(try Self.call(#"grep -rn "// UsageWindow" Sources --include=*.swift"#) == "where UsageWindow")
    }

    /// The extensions an enum case often spells are a member's name unless a path separator makes them a file's: `Spacing.md` is a case of `Spacing`, and `rules/Spacing.md` is a file.
    @Test(arguments: ["md", "csv", "html", "txt", "yaml", "yml", "plist"])
    func anExtensionACaseOftenSpellsIsAMemberWithoutASeparator(suffix: String) throws {
        #expect(try Self.call("grep -rn \"Spacing.\(suffix)\" Sources --include=*.swift") == "where Spacing")
        #expect(try Self.call("grep -rn \"rules/Spacing.\(suffix)\" Sources --include=*.swift") == "search")
        #expect(!PatternReading.spellsAFile("Spacing.\(suffix)"))
        #expect(PatternReading.spellsAFile("rules/Spacing.\(suffix)"))
    }

    /// An only-matching search prints what its pattern's variable part matched, so the name beside that part is context, never the member asked for.
    @Test
    func anOnlyMatchingExtractionLiftsNoMemberFromItsPattern() throws {
        #expect(try Self.call(#"grep -n -o 'destination: \.[a-zA-Z]*' /x/Theme.swift"#) == "digest Theme")
        #expect(try Self.call(#"grep -oE 'rule: "[a-zA-Z]+"' /x/Theme.swift"#) == "digest Theme")
        #expect(try Self.call(#"grep -oE 'UsageWindow\.for[A-Z][a-zA-Z]*' /x/Theme.swift"#) == "digest Theme")
        #expect(try Self.call(#"grep --only-matching 'kind: \.[a-z]*' /x/Theme.swift"#) == "digest Theme")
        // A pattern that is one name, a declaration or a call still names it.
        #expect(try Self.call(#"grep -o '\bslate\b' /x/Theme.swift"#) == "digest Theme.slate")
        #expect(try Self.call(#"grep -on 'func signedDelta' /x/Trend.swift"#) == "digest Trend.signedDelta")
        // Without -o the same pattern keeps its loose reading.
        #expect(try Self.call(#"grep -n 'destination: \.[a-zA-Z]*' /x/Theme.swift"#) == "digest Theme.destination")
    }

    /// A word beside a character class is a fragment of a name, which `search` asks for by `name:`, never a whole name for `where`.
    @Test
    func aWordBesideACharacterClassIsAFragment() throws {
        #expect(try Self.call(#"grep -rho -E 'UsageWindow[A-Z][a-zA-Z]+' Sources --include=*.swift"#) == "search name:UsageWindow")
        #expect(try Self.call(#"grep -rn 'Catalogue[A-Za-z]*Store' Sources --include=*.swift"#) == "search name:Catalogue name:Store")
        #expect(SweepPattern.reading(of: "Catalogue[A-Z]") == .shape("name:Catalogue"))
    }

    /// A member the index does not hold is never offered — the type-level call is what is actually there.
    ///
    /// `HelpTopics` declares no `only`, so a call offering it is a call that cannot answer; the fallback drops the member and keeps the type, exactly as a lookup with no member at all does.
    @Test
    func aMemberTheIndexDoesNotHoldFallsBackToTheType() {
        let digest = IndexSuggestion.forLookup(symbol: "only", file: "HelpTopics.swift", memberExists: { _, _ in false })
        #expect(digest.call == "digest HelpTopics")
        #expect(!digest.call.contains("only"))

        let whereLookup = IndexSuggestion.forLookup(symbol: "DepotStore.comparison", file: nil, memberExists: { _, _ in false })
        #expect(whereLookup.call == "where DepotStore")
        #expect(!whereLookup.call.contains("comparison"))
    }

    /// A member the index does hold is offered by its member path, whichever shape asked for it.
    @Test
    func aMemberTheIndexHoldsKeepsItsPath() {
        let digest = IndexSuggestion.forLookup(symbol: "isProse", file: "TextSearch.swift", memberExists: { _, _ in true })
        #expect(digest.call == "digest TextSearch.isProse")

        let whereLookup = IndexSuggestion.forLookup(symbol: "DepotStore.comparison", file: nil, memberExists: { _, _ in true })
        #expect(whereLookup.call == "where DepotStore.comparison")
    }

    /// A pattern that spells its own `Type.member` path — the regex form of a member access — builds the offer from that spelling, never from the bare member alone.
    @Test
    func aPatternThatSpellsItsOwnMemberPathIsOfferedByIt() throws {
        #expect(try Self.call(#"grep -rn "\<DepotStore\.comparison\>" Sources --include=*.swift"#) == "where DepotStore.comparison")
        #expect(try Self.call(#"grep -rn "DepotStore\.comparison" Sources --include=*.swift"#) == "where DepotStore.comparison")
        // A bare dot behind a capitalised type is the same member access, written as it reads.
        #expect(try Self.call(#"grep -rn "DepotStore.comparison" Sources --include=*.swift"#) == "where DepotStore.comparison")
        // A bare `.member` with nothing in front of the dot has no type to keep, and stays the bare word it
        // always was — inventing one is not this rule's job.
        #expect(try Self.call(#"grep -rn "\.comparison\b" Sources --include=*.swift"#) == "where comparison")
        // A word beside a data file's extension is still read as the type alone, never recombined into a
        // path that looks the same but is not one anyone escaped: `Depot.json` is unescaped and ambiguous
        // with a file's name, so it draws no member.
        #expect(try Self.call(#"grep -rn "Depot.json" Sources --include=*.swift"#) == "where Depot")
    }

    /// One call per name is the shape the hook judges against every name being declared; one file's digest standing on the same names is not it, and keeps its offer while any one of them is.
    ///
    /// The two are told apart by rebuilding the per-name call, since nothing records which of them a suggestion is, and a lone name is neither: it is the plain lookup, which the declaredness gate has already settled by then.
    @Test
    func onlyOneCallPerNameIsJudgedAgainstEveryName() {
        #expect(IndexSuggestion.forNames(["UsageWindow", "UsageLog"]).isOneCallPerName)
        #expect(!IndexSuggestion.forNames(["UsageWindow"]).isOneCallPerName)

        let digest = IndexSuggestion.forSearch(pattern: #"UsageWindow\|UsageLog"#, symbol: nil, file: "Sources/App/UsageWindow.swift")
        #expect(digest.symbols == ["UsageWindow", "UsageLog"])
        #expect(digest.call == "digest UsageWindow")
        #expect(!digest.isOneCallPerName)
    }
}
