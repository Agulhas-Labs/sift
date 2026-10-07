//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The searches and reads no index answer could stand in for, each let through by the hook and scored the same way by the scan — and, beside them, the lookups the index does answer, still refused.
///
/// **Measured before these rules, the refusal bought nothing for almost half the calls it stopped.** Of 163 lone refusals over four days, 75 were followed by the identical call re-run, each paying a whole context's round trip for an answer that could not replace what the command printed: a phrase from a comment, a string literal, a path under `.build/`, another revision's tree, a conflict marker, a window a `cat` pipes into `head`.
///
/// Every withholding is pinned at both ends, as `AdviceAgreementTests` pins the rules before them: the hook lets the call through and logs the rule that did, and the tally scores the same call out of the share. A rule that silences the hook and leaves the scan counting the call as a lookup the index lost lowers the share for exactly the calls the tool has just judged unanswerable.
@Suite(.temporaryDirectories)
struct NeverRefusedShapesTests {
    private static func shell(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command]]
    }

    private static func bash(_ command: String) -> Data {
        TranscriptFixture.toolUse("Bash", input: ["command": command])
    }

    private static func lookup(
        _ payload: [String: Any],
        noting log: SuppressionLog,
        couldAnswer: @escaping (String) -> Bool = { _ in true }
    ) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(command: nil, payload: payload, in: nil, noting: log) { name, _ in couldAnswer(name) }
    }

    /// Which count a rule's withholding belongs to: the half ``TextSearch/Reason`` declares for it, and the first half for `untargeted`, which is no rule of that type.
    ///
    /// An advisor that can name no call names no answer either, so there is no answer whose round trips could be weighed against the command — which is what the second half measures.
    private static func half(of rule: String) -> TextSearch.Withholding {
        TextSearch.Reason(rawValue: rule)?.withholding ?? .notRecorded
    }

    /// A shell call the hook lets through under `rule`, which the tally then scores out of the share — on the count for the half that rule is withheld on, and never on the other.
    private static func expectWithheld(_ command: String, as rule: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(lookup(shell(command), noting: recording.log) == nil, "\(command)", sourceLocation: sourceLocation)
        #expect(recording.rules == [rule], "\(command)", sourceLocation: sourceLocation)

        let tally = TranscriptFixture.tally([bash(command)])
        let half = half(of: rule)
        #expect(tally.textSearches == (half == .notRecorded ? 1 : 0), "\(command)", sourceLocation: sourceLocation)
        #expect(tally.withheldOnWorth == (half == .notWorthTheRoundTrips ? 1 : 0), "\(command)", sourceLocation: sourceLocation)
        #expect(tally.total == 0, "\(command)", sourceLocation: sourceLocation)
    }

    /// The same for a `Grep` or `Read` call's input.
    private static func expectWithheld(tool: String, input: [String: Any], as rule: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(lookup(["tool_name": tool, "tool_input": input], noting: recording.log) == nil, "\(input)", sourceLocation: sourceLocation)
        #expect(recording.rules == [rule], "\(input)", sourceLocation: sourceLocation)

        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse(tool, input: input)])
        let half = half(of: rule)
        #expect(tally.textSearches == (half == .notRecorded ? 1 : 0), "\(input)", sourceLocation: sourceLocation)
        #expect(tally.withheldOnWorth == (half == .notWorthTheRoundTrips ? 1 : 0), "\(input)", sourceLocation: sourceLocation)
        #expect(tally.total == 0, "\(input)", sourceLocation: sourceLocation)
    }

    // MARK: - Which half of the question a rule belongs to

    /// Every rule says which half it belongs to, and the two are counted apart: a lookup the index lost because the hook judged its answer not worth the round trips is not a lookup the index never owed.
    ///
    /// `notAName` is honest — "this is not a symbol question", the same family as `phrase` and `stringLiteral`. `contextLines`, `severalNames`, `filteredOutput` and `filesOnly` are not: the index can answer all four, and it is only the price of the answer that withholds them — `filteredOutput`'s own pattern is as often a name the index does declare as not. Pooling any of the four into the first half lets the share improve by redefinition, the number keeping its name and its report line while its meaning changes underneath.
    @Test
    func everyRuleSaysWhichHalfOfTheQuestionItAnswers() {
        let byHalf = Dictionary(grouping: TextSearch.Reason.allCases, by: \.withholding)

        #expect(byHalf[.notWorthTheRoundTrips] == [.contextLines, .severalNames, .filteredOutput, .filesOnly])
        #expect(byHalf[.notRecorded]?.contains(.notAName) == true)
        #expect(byHalf[.notRecorded]?.count == TextSearch.Reason.allCases.count - 4)
    }

    // MARK: - Phrases

    /// A grep of one file for prose, a comment marker or a call site is let through: a digest records none of them, so the digest the refusal offered was never the answer.
    @Test(arguments: [
        #"grep -n "stale gate is open" Sources/App/Depot.swift"#,
        #"grep -n "MARK: - Loading" Sources/App/Depot.swift"#,
        #"grep -n "// TODO" Sources/App/Depot.swift"#,
        #"grep -n "stock: stock(item, level: .high" Sources/App/Depot.swift"#,
        #"grep -n "the same gate.*shelve\|shelve(_:in:).*route strip ask" Tests/App/GizmoTests.swift"#,
    ])
    func aPhraseOnOneFileIsWithheldAndScoredAsATextSearch(command: String) throws {
        try Self.expectWithheld(command, as: "phrase")
    }

    /// The `Grep` spelling of the same search meets the same answer.
    @Test
    func aPhraseOnOneFileIsWithheldOnTheGrepSurfaceToo() throws {
        try Self.expectWithheld(tool: "Grep", input: ["output_mode": "content", "pattern": "stale gate is open", "path": "Sources/App/Depot.swift"], as: "phrase")
    }

    /// Declaration shape on one file is still the file's digest, answered in place where the shape is proven — the phrase rule takes nothing from the lookups the index serves.
    @Test(arguments: [
        (#"grep -n "func save" Sources/App/Depot.swift"#, "digest Depot.save"),
        (#"grep -n "final class" Sources/App/Depot.swift"#, "digest Depot"),
        (#"grep -rn "\bdepot\b" Sources --include=*.swift"#, "where depot"),
        ("cat Sources/App/Depot.swift", "digest Depot"),
    ])
    func aLookupTheIndexAnswersIsStillRefusedAndAnsweredInPlace(command: String, call: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        let refusal = Self.lookup(Self.shell(command), noting: recording.log)

        #expect(refusal?.suggestion.call == call)
        #expect(refusal?.inPlace != nil)
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    // MARK: - Names no index declares

    /// A sweep for an alternation of words no index declares is withheld and scored out of the share on those names — and so is one only some of whose names are declared, since the offer is one `where` per name and the ask was every one of them.
    ///
    /// The same alternation confined to one file is withheld a rule earlier now, on the arithmetic rather than on the names (``anAlternationOfNamesOnTheFilesItNamesIsWithheld``): across a tree the resolved sites are worth the calls, and in one file they are not.
    @Test
    func anAlternationOfUndeclaredWordsIsWithheldAcrossATree() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let sweep = #"grep -rn "backfill\|sprocket" Sources --include=*.swift"#

        #expect(Self.lookup(Self.shell(sweep), noting: recording.log) { _ in false } == nil)
        #expect(recording.rules == ["unknownName"])
        #expect(TranscriptFixture.tally([Self.bash(sweep)], couldAnswer: { _, _ in false }).textSearches == 1)

        let declared: (String) -> Bool = { $0 == "sprocket" }
        #expect(Self.lookup(Self.shell(sweep), noting: recording.log, couldAnswer: declared) == nil)
        #expect(recording.rules == ["unknownName", "partlyDeclared"])
        // One name declared and one not: the index answers for what it has, one `where` apiece, so this
        // half of the pair is withheld on the cost of asking rather than on anything it does not record.
        #expect(TranscriptFixture.tally([Self.bash(sweep)], couldAnswer: { name, _ in declared(name) }).withheldOnWorth == 1)

        #expect(Self.lookup(Self.shell(sweep), noting: recording.log)?.suggestion.call == "where backfill\nwhere sprocket")
        #expect(TranscriptFixture.tally([Self.bash(sweep)]).cold == 1)
    }

    // MARK: - A pattern that could not be a name

    /// A pattern no Swift name could be — flag text, whitespace around it, a regex's wildcard dot — is let through, because the `digest <File>.<word>` it was refused with is built from a word the pattern never asked about on its own.
    ///
    /// Every one of these was measured being refused and then answered by re-running the identical command, which is a whole context's round trip spent on a nudge that could not have helped.
    @Test(arguments: [
        #"grep -n -e "--only" Sources/App/Depot.swift"#,
        #"grep -n -- "  --only " Sources/App/Depot.swift"#,
        #"grep -n "tab.about" Sources/App/Depot.swift"#,
        #"grep -n "don't" Sources/App/Depot.swift"#,
    ])
    func aPatternThatCouldNotBeANameIsWithheld(command: String) throws {
        try Self.expectWithheld(command, as: "notAName")
    }

    /// The fourth shape of the same report is the string literal's rule, which already held: a pattern quoting a literal is withheld before this one is asked.
    @Test
    func aQuotedLiteralOnOneFileKeepsTheStringLiteralRule() throws {
        try Self.expectWithheld(#"grep -n '"test"' Sources/App/Depot.swift"#, as: "stringLiteral")
    }

    /// Declaration syntax is still a lookup however it is spaced: the whitespace this rule reads is whitespace no declaration's form explains.
    @Test(arguments: [
        (#"grep -n "func save" Sources/App/Depot.swift"#, "digest Depot.save"),
        (#"grep -n "^\s*static let" Sources/App/Depot.swift"#, "digest Depot"),
    ])
    func aDeclarationsOwnWhitespaceIsStillALookup(command: String, call: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == call)
        #expect(recording.rules.isEmpty)
    }

    /// A regex's *spelling* of whitespace is not the padding this mark was drawn from: `name\s*(` is the canonical way to grep for one function, and the mark is literal whitespace or nothing.
    ///
    /// Measured: `grep -n "isProse\s*(" TextSearch.swift` was withheld where the same search without the quantifier was refused with the member's digest — the one right answer — so the widest reading of the mark silenced the shape it exists to leave alone. `func reason\s*(` survived only by opening on `func`, which is an accident of that pattern rather than a rule.
    @Test(arguments: [
        (#"grep -n "save\s*(" Sources/App/Depot.swift"#, "digest Depot.save"),
        (#"grep -n "save\t" Sources/App/Depot.swift"#, "digest Depot.save"),
    ])
    func aRegexSpellingOfWhitespaceIsStillTheNamesLookup(command: String, call: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == call)
        #expect(recording.rules.isEmpty)
    }

    /// `[[:space:]]` is the exception among the spellings, because it is itself a word.
    ///
    /// The offer built from `save[[:space:]]*(` is `digest Depot.space` — the member nobody asked about that this rule exists to catch. The escapes carry no word to be mistaken for one; this spelling does.
    @Test
    func aBracketedSpaceClassIsStillAPatternThatCouldNotBeAName() throws {
        try Self.expectWithheld(#"grep -n "save[[:space:]]*(" Sources/App/Depot.swift"#, as: "notAName")
    }

    // MARK: - Context around the matches in one file

    /// A grep of one named file with `-A`/`-B`/`-C`, for anything but a member's declaration, is the ranged read the guidance itself asks for after a digest: `where` gives the location and the digest the shape, and neither gives the eight lines.
    ///
    /// A `struct Depot` grep is the file's declarations rather than one member's, and a digest numbers declarations with nothing between them, so the context around them is no more served than a use of a bare name is.
    @Test(arguments: [
        #"grep -n "matchedLines" -A8 Sources/App/Depot.swift"#,
        #"grep -n "matchedLines" -B2 -A2 Sources/App/Depot.swift"#,
        #"grep -nA 8 "matchedLines" Sources/App/Depot.swift"#,
        #"grep -n --context=3 "matchedLines" Sources/App/Depot.swift"#,
        #"grep -n "struct Depot" -A5 Sources/App/Depot.swift"#,
    ])
    func aContextGrepOfOneFileIsWithheld(command: String) throws {
        try Self.expectWithheld(command, as: "contextLines")
    }

    /// The `Grep` spelling of the same read meets the same answer, or the tool becomes the way around the refusal.
    @Test
    func aContextGrepIsWithheldOnTheGrepSurfaceToo() throws {
        try Self.expectWithheld(tool: "Grep", input: ["output_mode": "content", "pattern": "matchedLines", "path": "Sources/App/Depot.swift", "-A": 8], as: "contextLines")
    }

    /// A member's declaration with context around it is the one shape this rule stands aside for: the hook runs the grep and hands that member's source back, one round trip, which is the best outcome on offer and strictly better than silence.
    ///
    /// Withholding it deleted an answer rather than a useless nudge — `InPlaceShape.grepCall` allows context for a member's declaration precisely because the member's source accounts for every line printed — and `grep -n "func X" -A20 File.swift` is among the commonest shapes an agent writes.
    @Test(arguments: [
        #"grep -n "func matchedLines" -A8 Sources/App/Depot.swift"#,
        #"grep -n "func matchedLines" -B2 -A2 Sources/App/Depot.swift"#,
        #"grep -n --context=3 "func matchedLines" Sources/App/Depot.swift"#,
    ])
    func aContextGrepOfAMembersDeclarationIsStillItsLookup(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == "digest Depot.matchedLines")
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).textSearches == 0)
    }

    /// The `Grep` spelling of that one meets the same answer too, in the direction that matters here: a refusal carrying the member's call, not a withholding.
    @Test
    func aContextGrepOfAMembersDeclarationIsItsLookupOnTheGrepSurfaceToo() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let input: [String: Any] = ["output_mode": "content", "pattern": "func matchedLines", "path": "Sources/App/Depot.swift", "-A": 8]

        #expect(Self.lookup(["tool_name": "Grep", "tool_input": input], noting: recording.log)?.suggestion.call == "digest Depot.matchedLines")
        #expect(recording.rules.isEmpty)
    }

    /// Without the context flags the same search is the member's source, still refused and answered in place.
    @Test
    func theSameGrepWithoutContextIsStillTheMembersLookup() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        let refusal = Self.lookup(Self.shell(#"grep -n "func matchedLines" Sources/App/Depot.swift"#), noting: recording.log)

        #expect(refusal?.suggestion.call == "digest Depot.matchedLines")
        #expect(recording.rules.isEmpty)
    }

    // MARK: - An alternation of names, confined to the files it searches

    /// Two or more names alternating, in files the search names outright, is one grep against one `where` per name — and the refusal's own words for the offer are "a search for several is that many questions".
    @Test(arguments: [
        #"grep -n "waitForExit|temporaryLog" Sources/App/Depot.swift"#,
        #"grep -n "waitForExit\|temporaryLog" Sources/App/Depot.swift"#,
        #"grep -n "backfill\|sprocket" Sources/App/Depot.swift"#,
        #"grep -n "waitForExit|temporaryLog" Sources/App/Depot.swift Sources/App/Shelf.swift"#,
        #"grep -n "backfill|sprocket|pending|shipped|signedDelta" Sources/App/*.swift"#,
    ])
    func anAlternationOfNamesOnTheFilesItNamesIsWithheld(command: String) throws {
        try Self.expectWithheld(command, as: "severalNames")
    }

    /// A `Grep` confines a search by its glob where the shell confines one by the files the glob expanded to, so the two surfaces have to read it the same way.
    ///
    /// Measured: `Grep(pattern: "printsContext|onlyMatching", glob: "Sources/SiftMCP/*.swift")` denied with one `where` per name — the two-round-trips-for-one-grep offer this rule exists to stop — while the identical `grep -n "printsContext|onlyMatching" Sources/SiftMCP/*.swift` was silent, because the shell expands the glob and the tool carries it. Which surface a caller reaches for cannot change the answer.
    @Test(arguments: [
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "glob": "Sources/App/*.swift"],
        ["output_mode": "content", "pattern": #"waitForExit\|temporaryLog"#, "glob": "Sources/App/*.swift"],
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "glob": "Sources/App/Depot.swift"],
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "path": "Sources/App/Depot.swift"],
    ])
    func anAlternationIsWithheldOnTheGrepSurfaceToo(input: [String: String]) throws {
        try Self.expectWithheld(tool: "Grep", input: input, as: "severalNames")
    }

    /// A glob that floats over the tree is the `--include=*.swift` sweep, not a set of named files, so the same alternation keeps its nudge on this surface as it does at the shell.
    @Test(arguments: [
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "glob": "*.swift"],
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "glob": "**/*.swift"],
        ["output_mode": "content", "pattern": "waitForExit|temporaryLog", "glob": "Sources/**/*.swift"],
    ])
    func aFloatingGlobKeepsTheAlternationsNudge(input: [String: String]) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(["tool_name": "Grep", "tool_input": input], noting: recording.log)?.suggestion.symbols == ["waitForExit", "temporaryLog"])
        #expect(recording.rules.isEmpty)
    }

    /// The same alternation swept across a tree keeps its nudge: there the names' resolved sites are what a raw sweep cannot give, which is the case `where` exists for.
    @Test(arguments: [
        #"grep -rn "waitForExit\|temporaryLog" Sources --include=*.swift"#,
        #"grep -rn "waitForExit|temporaryLog" Sources --include=*.swift"#,
    ])
    func theSameAlternationSweptAcrossATreeIsStillRefused(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.symbols == ["waitForExit", "temporaryLog"])
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    /// One name is one call, so the arithmetic that lets an alternation through never reaches a single name's search.
    @Test
    func aSingleNameOnOneFileIsStillItsLookup() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(#"grep -n "waitForExit" Sources/App/Depot.swift"#), noting: recording.log)?.suggestion.call == "digest Depot.waitForExit")
        #expect(recording.rules.isEmpty)
    }

    // MARK: - Declaration syntax beside a name

    /// A branch that is only declaration syntax — `final class`, `@Test func` — carries no name of its own, but it is not prose either, so it never empties an alternation that carries a name beside it: the sweep is still refused with `where`, and the tally still counts it as the miss it is, rather than scoring it a text search out of the share.
    @Test(arguments: [
        #"grep -rn "final class\|signedDelta" Sources --include=*.swift"#,
        #"grep -rn "@Test func\|signedDelta" Sources --include=*.swift"#,
    ])
    func declarationSyntaxBesideANameIsStillRefusedAsTheNamesLookup(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == "where signedDelta")
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
        #expect(TranscriptFixture.tally([Self.bash(command)]).textSearches == 0)
    }

    /// The same beside a plain lowercase name — the one kind a prose branch drops — where the declaration's form is anchored, spaced by `\s*`, or opened by a modifier: `InPlaceShape` reads each of these as a declaration's form, and so must the sweep, or the lookup `where save` answers is withheld and scored out of the share.
    @Test(arguments: [
        #"grep -rn "^final class\|save" Sources --include=*.swift"#,
        #"grep -rn "^\s*static let\|save" Sources --include=*.swift"#,
        #"grep -rn "mutating func\|save" Sources --include=*.swift"#,
    ])
    func declarationFormBesideAPlainNameIsStillRefusedAsTheNamesLookup(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == "where save")
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
        #expect(TranscriptFixture.tally([Self.bash(command)]).textSearches == 0)
    }

    // MARK: - String literals, fixed strings and conflict markers

    /// A pattern holding a `"` hunts a string literal, which no index records — judged over every `-e` pattern, so the literal is found wherever among them it stands.
    @Test(arguments: [
        #"grep -rn --include='*.swift' -e '"\.cache' -e 'vendor' -e 'Artifacts' Sources/App Sources/Kit"#,
        #"grep -rn --include='*.swift' -e 'vendor' -e 'Artifacts' -e '"\.cache' Sources/App Sources/Kit"#,
        #"grep -n '"pending"' Sources/App/Depot.swift"#,
    ])
    func aStringLiteralIsWithheldAndScoredAsATextSearch(command: String) throws {
        try Self.expectWithheld(command, as: "stringLiteral")
    }

    /// The `Grep` surface reaches the same verdict on the same literal.
    @Test
    func aStringLiteralIsWithheldOnTheGrepSurfaceToo() throws {
        try Self.expectWithheld(tool: "Grep", input: ["output_mode": "content", "pattern": #""pending""#, "glob": "*.swift"], as: "stringLiteral")
    }

    /// Several `-e` patterns naming declared symbols are still the sweep for them: refused, and counted as the miss it is.
    @Test
    func severalPatternsNamingSymbolsAreStillRefused() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn --include='*.swift' -e 'Depot' -e '\.pending' -e '\.shipped' Sources"#

        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call.hasPrefix("where Depot") == true)
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    /// A fixed-string search for anything but a name is a literal the index cannot read as one — `stock(`, `[0]`, `.cache` are characters, not the regex or the name they would otherwise be taken for.
    @Test(arguments: [
        "grep -nF 'stock(' Sources/App/Depot.swift",
        "fgrep -rn '[0]' Sources --include=*.swift",
        "grep -rn --fixed-strings '.cache' Sources --include=*.swift",
    ])
    func aFixedStringIsWithheldAndScoredAsATextSearch(command: String) throws {
        try Self.expectWithheld(command, as: "fixedString")
    }

    /// A fixed-string search for one name is that name's sweep, whatever flag spells it: refused with `where`, and answered in place where it is word-anchored.
    @Test
    func aFixedStringNamingOneSymbolIsStillItsSweep() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let command = "grep -rn -w -F Depot Sources --include=*.swift"

        let refusal = Self.lookup(Self.shell(command), noting: recording.log)

        #expect(refusal?.suggestion.call == "where Depot")
        #expect(refusal?.inPlace != nil)
        #expect(recording.rules.isEmpty)
    }

    /// An unresolved merge's markers are text no index records, in a file or across a tree, on either surface.
    @Test(arguments: [
        #"grep -n "^<<<<<<<" Sources/App/Depot.swift"#,
        #"grep -n "^=======" Sources/App/Depot.swift"#,
        #"grep -n "^<<<<<<<\|^>>>>>>>" Sources/App/Depot.swift"#,
        #"grep -rn ">>>>>>>" Sources --include=*.swift"#,
    ])
    func aConflictMarkerIsWithheldAndScoredAsATextSearch(command: String) throws {
        try Self.expectWithheld(command, as: "conflictMarkers")
    }

    @Test
    func aConflictMarkerIsWithheldOnTheGrepSurfaceToo() throws {
        try Self.expectWithheld(tool: "Grep", input: ["output_mode": "content", "pattern": "^>>>>>>>", "path": "Sources/App/Depot.swift"], as: "conflictMarkers")
    }

    // MARK: - Outside the indexed sources

    /// A read or a search of a tree no index holds — build output, a dependency's checkout, a scratch file — is let through on every surface, and scored out of the share.
    @Test(arguments: [
        "grep -rn Syntax .build/checkouts/kit/Sources --include=*.swift",
        "cat .build/checkouts/kit/Sources/Depot.swift",
        #"grep -n "func save" /tmp/scratch-depot/Depot.swift"#,
        "grep -rn Depot ~/Library/Developer/Xcode/DerivedData/App/kit --include=*.swift",
    ])
    func aShellLookupOutsideTheIndexedSourcesIsWithheld(command: String) throws {
        try Self.expectWithheld(command, as: "outsideSources")
    }

    @Test
    func aGrepOutsideTheIndexedSourcesIsWithheld() throws {
        try Self.expectWithheld(tool: "Grep", input: ["output_mode": "content", "pattern": "Depot", "path": ".build/checkouts/kit", "glob": "*.swift"], as: "outsideSources")
    }

    @Test
    func aWholeReadOutsideTheIndexedSourcesIsWithheld() throws {
        try Self.expectWithheld(tool: "Read", input: ["file_path": "/repo/.build/checkouts/kit/Sources/Depot.swift"], as: "outsideSources")
    }

    // MARK: - Outside the indexed sources, judged relative to the call's own cwd

    /// A repository that merely sits inside a directory named `checkouts` is indexed like any other, on both surfaces — the indexer excludes that name only relative to the repository it walks, and Claude Code always hands a whole `Read` an absolute path.
    ///
    /// Refused as the miss it is instead — `digest`, not withheld — and the scan counts it cold rather than scoring it out of the share.
    @Test
    func aPathInsideARepositoryNamedLikeAnExcludedDirectoryIsNotWithheld() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let cwd = "/Users/x/checkouts/App/Sources"
        let path = "/Users/x/checkouts/App/Sources/View.swift"
        let input: [String: Any] = ["file_path": path]

        let refusal = PreToolUseCommand.lookup(command: nil, payload: ["tool_name": "Read", "tool_input": input], in: cwd, noting: recording.log)

        #expect(refusal?.suggestion.call == "digest View")
        #expect(recording.rules.isEmpty)
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Read", input: input, cwd: cwd)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// The same repository read through `Grep` rather than `Read`.
    @Test
    func aGrepInsideARepositoryNamedLikeAnExcludedDirectoryIsNotWithheld() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let cwd = "/Users/x/checkouts/App/Sources"
        let input: [String: Any] = ["output_mode": "content", "pattern": "Depot", "path": "/Users/x/checkouts/App/Sources/View.swift"]

        #expect(PreToolUseCommand.lookup(command: nil, payload: ["tool_name": "Grep", "tool_input": input], in: cwd, noting: recording.log) != nil)
        #expect(recording.rules.isEmpty)
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Grep", input: input, cwd: cwd)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// An excluded directory genuinely inside the tree the call's own `cwd` stands in is still refused on both surfaces, whichever of ``SwiftTree/neverIndexed`` it is named for, and the scan still counts it out of the share.
    @Test(arguments: [
        ("/Users/x/App/Pods/Kit/File.swift", "/Users/x/App"),
        ("/Users/x/App/checkouts/Kit/File.swift", "/Users/x/App"),
        ("/Users/x/checkouts/App/.build/checkouts/kit/A.swift", "/Users/x/checkouts/App"),
    ])
    func anExcludedDirectoryInsideTheCwdsTreeIsStillWithheld(path: String, cwd: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let input: [String: Any] = ["file_path": path]

        #expect(PreToolUseCommand.lookup(command: nil, payload: ["tool_name": "Read", "tool_input": input], in: cwd, noting: recording.log) == nil)
        #expect(recording.rules == ["outsideSources"])
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Read", input: input, cwd: cwd)])
        #expect(tally.textSearches == 1)
        #expect(tally.total == 0)
    }

    // MARK: - Other revisions

    /// A `git grep` of a tree named before `--` searches that tree, whatever spells it — a variable holding a revision reads exactly as `origin/…` does.
    ///
    /// Neither end counts it a lookup, and the hook logs the rule that decided.
    @Test(arguments: [
        "git grep -n pending $T -- Sources/App/Depot.swift",
        "git grep -n pending feature -- 'Sources/*.swift'",
    ])
    func aSearchOfAnotherRevisionIsLetThroughAndLogged(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log) == nil)
        #expect(recording.rules == ["anotherRevision"])
        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.total == 0)
        #expect(tally.textSearches == 0)
    }

    /// Another revision read whole, or its patches, opens nothing in the working tree: no lookup at either end.
    @Test(arguments: ["git show HEAD:Sources/App/Depot.swift", "git log -p -- Sources/App/Depot.swift"])
    func aReadOfAnotherRevisionIsNoLookup(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(Self.shell(command), noting: recording.log) == nil)
        #expect(TranscriptFixture.tally([Self.bash(command)]).total == 0)
    }

    // MARK: - Shell windows

    /// A file piped whole into a window prints only the window, and is the ranged read it stands for at both ends: judged by the hook as a window into that file, withheld by no rule, and scored as one.
    @Test(arguments: [
        "cat -n Sources/App/Depot.swift | sed -n '1,140p'",
        "cat Sources/App/Depot.swift | head -80",
        "awk 'NR>=10 && NR<=40' Sources/App/Depot.swift",
    ])
    func aWindowOnAPipedReadIsARangedReadAtBothEnds(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(ShellInspection.windowedReadPath(command, in: nil) == "Sources/App/Depot.swift")
        #expect(Self.lookup(Self.shell(command), noting: recording.log)?.suggestion.call == "digest Depot")
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A search after the `cat` is no window: what it prints is chosen by its pattern, not by line numbers.
    @Test
    func aSearchPipedFromAReadIsNoWindow() {
        #expect(ShellInspection.windowedReadPath("cat Sources/App/Depot.swift | grep -n stock | head -5", in: nil) == nil)
    }

    /// A `<<` inside a quoted pattern is characters, not a heredoc handing the search its text: the search is of the file it names, and a lookup like any other — while an unquoted here-string still hands the verb inline text.
    @Test
    func aQuotedShiftInAPatternIsNoInlineText() {
        #expect(ShellInspection.isSwiftLookup(#"grep -n "<<" Sources/App/Depot.swift"#))
        #expect(!ShellInspection.isSwiftLookup(#"grep -n stock <<< "$text""#))
    }
}

// MARK: - A tree with no repository for the offered call to be rooted at

/// The second of the two rules about the *tree* rather than the question: a call naming a path is answered by reading that exact path under a root, so a path standing outside every repository leaves it nothing to resolve (`RepositoryIndex.isRootless`).
///
/// Each fixture is a real tree, because that is the whole of what the rule reads — a repository, or the absence of one, and the file actually being there.
extension NeverRefusedShapesTests {
    /// A document long enough to be worth an outline: past the floor in both of its units, and nothing a fixture's length could make ambiguous.
    private static var document: String {
        (1 ... 200).map { "Line \($0) of a plan nobody has put in a repository." }.joined(separator: "\n")
    }

    /// A whole read of a document standing outside every repository draws nothing.
    ///
    /// `digest <path>` is answered by reading that exact path under a root, and a path with no repository above it resolves none — the call answers `… is in no repository to root at — read it directly`, which is the read the refusal just denied, charged a whole context re-send to say. Markdown is where the shape is the everyday one, since a `.md` target is always its own path: a vault note, a rule file under `~/.claude`, a plan in a home directory. `/tmp` was the only such tree an earlier rule already caught (`outsideSources`).
    @Test
    func aWholeReadOfADocumentInNoRepositoryIsWithheld() throws {
        let loose = try TemporaryDirectory.make("rootless")
        let document = loose.appendingPathComponent("Plan.md")
        try Data(Self.document.utf8).write(to: document)
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let input: [String: Any] = ["file_path": document.path]

        #expect(Self.lookup(["tool_name": "Read", "tool_input": input], noting: recording.log) == nil)
        #expect(recording.rules == ["noRepository"])
        // And nothing leaves the share by it: a document read is no Swift lookup at either end anyway.
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Read", input: input)])
        #expect(tally.total == 0)
    }

    /// The same read inside an indexed repository still draws `digest <path>` — the rule is about the tree the offered call would be rooted at, never about the subject being Markdown.
    @Test
    func aWholeReadOfADocumentInAnIndexedRepositoryStillDrawsItsOutline() throws {
        let repository = try TemporaryDirectory.make("rooted")
        let manager = FileManager.default
        try manager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let cache = SiftPaths.cache(in: repository)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent(SiftPaths.indexFileName))
        let documents = repository.appendingPathComponent("Docs", isDirectory: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        let document = documents.appendingPathComponent("Design.md")
        try Data(Self.document.utf8).write(to: document)
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        let refusal = try #require(Self.lookup(["tool_name": "Read", "tool_input": ["file_path": document.path]], noting: recording.log))

        #expect(refusal.suggestion.call == "digest \(document.path)")
        #expect(recording.rules.isEmpty)
    }

    /// And the rule is general: a Swift file the advisor can only name by its *path* is withheld in the same tree, while one it names by a stem is refused there as it always was — that call is resolved out of whatever index the caller's own root holds, so it is a call that can be made.
    @Test
    func aSwiftPathTargetIsWithheldWhereAStemTargetIsNot() throws {
        let loose = try TemporaryDirectory.make("rootless-source")
        let body = (1 ... 80).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let source = "struct Gizmo {\n\(body)\n}\n"
        let spaced = loose.appendingPathComponent("My Gizmo.swift")
        let stemmed = loose.appendingPathComponent("Gizmo.swift")
        try Data(source.utf8).write(to: spaced)
        try Data(source.utf8).write(to: stemmed)
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(["tool_name": "Read", "tool_input": ["file_path": spaced.path]], noting: recording.log) == nil)
        #expect(recording.rules == ["noRepository"])

        let refusal = try #require(Self.lookup(["tool_name": "Read", "tool_input": ["file_path": stemmed.path]], noting: recording.log))
        #expect(refusal.suggestion.call == "digest Gizmo")
    }
}
