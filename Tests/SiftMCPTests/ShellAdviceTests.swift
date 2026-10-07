//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the mapping from a shell lookup to the call that would have answered it.
///
/// **The shapes here are real; the symbols are not.** Every command was taken from a real transcript, because a mapping tuned against invented commands is tuned against the wrong distribution. What was kept is the shape each command has: which flags it carries, where the pattern sits, how many paths follow it, whether the pattern names a member or a type. The symbols inside them were replaced, and nothing the classifier reads depends on the words.
@Suite(.temporaryDirectories)
struct ShellAdviceTests {
    private static func call(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(ShellAdvice.suggestion(for: command), sourceLocation: sourceLocation).call
    }

    /// A whole-file read is the shape `digest` exists to replace — it serves the same question at a fraction of the cost.
    @Test
    func aWholeFileReadOfOneFileBecomesADigestOfIt() throws {
        #expect(try Self.call("cat Tests/SiftMCPTests/DigestFloorTests.swift") == "digest DigestFloorTests")
    }

    /// A windowed read is advised as the read of its one file, whichever tool spells it: whether anything already located the file is the hook's question, since only the hook knows what the context has been handed.
    ///
    /// A pattern address is not a window; it searches, and keeps its own nudge.
    @Test
    func aWindowedReadOfOneFileIsAdvisedAsTheReadOfIt() throws {
        #expect(try Self.call("sed -n '330,420p' Sources/SiftCore/DigestRenderer.swift") == "digest DigestRenderer")
        // Several windows in one address list are still a window of the one file.
        #expect(try Self.call("sed -n '140,170p;375,405p' Sources/SiftCore/DigestRenderer.swift") == "digest DigestRenderer")
        #expect(try Self.call("head -50 /x/WireID.swift") == "digest WireID")
        #expect(try Self.call("tail -n 40 Sources/App/View.swift") == "digest View")

        #expect(try Self.call("sed -n '/init/p' Sources/App/View.swift") == "digest View")
    }

    /// The flagship mapping: a grep for one name in one file is that member's source, which is one call.
    @Test
    func aGrepForOneNameInOneFileBecomesAMemberDigest() throws {
        #expect(try Self.call(#"grep -n "classifyEdgeWear" -A20 /x/CrateClassifier.swift"#) == "digest CrateClassifier.classifyEdgeWear")
        #expect(try Self.call(#"grep -n "func signedDelta" -A15 /x/Trend.swift"#) == "digest Trend.signedDelta")
    }

    /// A call site names what precedes the paren, not the argument inside it.
    @Test
    func aCallPatternNamesTheCalleeNotItsArgument() throws {
        #expect(try Self.call(#"grep -n "deviation(maxDev" /x/BarChart.swift"#) == "digest BarChart.deviation")
    }

    /// Word boundaries are regex, not name characters.
    @Test
    func escapesInAPatternAreNotPartOfTheName() throws {
        #expect(try Self.call(#"grep -n "\bsummary\b" /x/OverviewPanel.swift"#) == "digest OverviewPanel.summary")
    }

    /// A sweep across a tree is asking where a symbol is, which is `where` — there is no one file to digest.
    @Test
    func aSweepBecomesWhere() throws {
        #expect(try Self.call(#"grep -rn "WidgetRow" --include="*.swift" /x /y; sed -n '1,5p' a.swift"#) == "where WidgetRow")
        #expect(try Self.call(#"grep -rn "throughputTrend" /x/A.swift /x/B.swift"#) == "where throughputTrend")
    }

    /// `digest RangeBounds.RangeBounds` resolves to nothing: the pattern is looking for the type, and the file is named after it.
    @Test
    func aTypeIsNotSuggestedAsAMemberOfItself() throws {
        #expect(try Self.call(#"grep -n "struct RangeBounds" -A 30 /x/RangeBounds.swift"#) == "digest RangeBounds")
    }

    /// Alternation is two questions at once, so no single symbol is named — but the file is still worth a digest, and this is the case that can fall through a classifier entirely.
    @Test
    func alternationFallsBackToTheFileRatherThanGuessingASymbol() throws {
        #expect(try Self.call(#"grep -n "slateDim\|case sm\b\|slate" /x/Theme.swift"#) == "digest Theme")
    }

    /// Nothing to advise on: the command is not a lookup at all.
    ///
    /// Silence is the contract — the hook must not speak about builds, commits, edits, or files that are not Swift.
    @Test
    func nonLookupsGetNoSuggestion() {
        #expect(ShellAdvice.suggestion(for: "swift build 2>&1 | grep -n error Sources/Foo.swift") == nil)
        #expect(ShellAdvice.suggestion(for: "git add Foo.swift && git commit -m x | tail -1") == nil)
        #expect(ShellAdvice.suggestion(for: "sed -i '' 's/a/b/' Sources/Foo.swift") == nil)
        #expect(ShellAdvice.suggestion(for: "cat README.md") == nil)
        #expect(ShellAdvice.suggestion(for: "ls Sources/") == nil)
    }

    /// Reading this tool's own state must not draw a nudge — a false positive that would fire on every check of the adoption numbers.
    ///
    /// Each command here reads a file under `~/.sift/` — the usage log, the roots registry, the advice ledger, a status-line record — and none of them names a Swift file, so none draws a suggestion; one would offer `search` for a `.json`.
    @Test
    func inspectingTheToolsOwnStateDrawsNoNudge() {
        #expect(ShellAdvice.suggestion(for: "cat ~/.sift/usage.jsonl") == nil)
        #expect(ShellAdvice.suggestion(for: "ls -la ~/.sift/advice && cat ~/.sift/roots.json") == nil)
        #expect(ShellAdvice.suggestion(for: "head -c 900 ~/.sift/advice/session.json") == nil)
        #expect(ShellAdvice.suggestion(for: "cat ~/.sift/statusline/session.json | head -40") == nil)
    }

    /// A quoted command inside `echo` is text, not an invocation — the quotes are what keep it from reading as one.
    @Test
    func aQuotedCommandIsNotAnInvocation() {
        #expect(ShellAdvice.suggestion(for: #"echo "grep Foo.swift""#) == nil)
    }

    /// A substitution is one value, not a place where a new command starts.
    ///
    /// Split at the substitution's inner `|`, its `-t` and the path after it would land in `cat`'s argument list, where `-t` before a path that spells "swift" reads as ripgrep's `-t swift` — a denied lookup of a `.json` file. The directory spells "swift" for exactly that reason: a path that did not would pass whether or not the substitution were kept whole. Kept whole, neither command draws a suggestion.
    @Test
    func aCommandSubstitutionStaysInsideItsSegment() {
        #expect(ShellAdvice.suggestion(
            for: "cat ~/.cache/swift-advice/$(ls -t ~/.cache/swift-advice | head -1) 2>/dev/null; echo ---; ls -la ~/.local/bin/sift"
        ) == nil)
        #expect(ShellAdvice.suggestion(for: "cat `ls -t ~/.cache/swift-advice`") == nil)
    }

    /// `-A 20` is a context flag and its value is not the pattern.
    @Test
    func flagValuesAreNotMistakenForThePattern() throws {
        #expect(try Self.call(#"grep -A 20 -B 5 "renderHeader" /x/Renderer.swift"#) == "digest Renderer.renderHeader")
    }

    /// `-e` is how a pattern beginning with `-` is written, so it introduces the pattern rather than consuming an unrelated value.
    @Test
    func aPatternIntroducedByDashEIsFound() throws {
        #expect(try Self.call(#"grep -n -e "applyCoupon" /x/Catalogue.swift"#) == "digest Catalogue.applyCoupon")
    }

    /// The sweep that named no `.swift` and so could never be advised on: with a directory to resolve against, it gets the same answer its `--include=*.swift` twin already got.
    @Test
    func aTreeSweepIsAdvisedOnceTheTreeCanBeResolved() throws {
        let root = try TemporaryDirectory.make("shelladvice")
            .appendingPathComponent("shelladvice", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: sources.appendingPathComponent("View.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ShellAdvice.suggestion(for: "grep -rn UsageWindow Sources/") == nil)
        #expect(ShellAdvice.suggestion(for: "grep -rn UsageWindow Sources/", in: root.path)?.call == "where UsageWindow")
        // A tree-wide search for prose is still nobody's business: the index does not hold comments.
        #expect(ShellAdvice.suggestion(for: #"grep -rn "revisit this later" Sources/"#, in: root.path) == nil)
    }

    /// A language filter names Swift without naming a file, and needs no directory at all.
    @Test
    func aSwiftTypeFilterIsAdvisedOnItsOwn() throws {
        #expect(try Self.call("rg -t swift UsageWindow Sources/") == "where UsageWindow")
    }

    /// A `git grep` handed a revision searches some other tree, and the index answers the working one — advising `where` against it is wrong advice.
    ///
    /// A nudge on `git grep … origin/<branch> -- <paths>` is one the model rightly ignores, and the ledger reads the ignoring as unheeded — so wrong advice here quiets the hook for the lookups it should have caught.
    @Test
    func aRevisionScopedGitGrepDrawsNoNudge() {
        #expect(ShellAdvice.suggestion(for: #"git grep -n "func signedDelta" origin/feature-branch -- Sources/Trend.swift"#) == nil)
        #expect(ShellAdvice.suggestion(for: #"git grep -n "protocol Localizable" HEAD~3 -- Sources/Localizable.swift"#) == nil)
        #expect(ShellAdvice.suggestion(for: #"git grep --cached "applyCoupon" -- Sources/Catalogue.swift"#) == nil)
    }

    /// The same grep of the working tree keeps its nudge — and names the *pattern's* symbol, not the subcommand: reading operands from "the second token" would make `grep` the pattern of every `git grep`.
    @Test
    func aWorkingTreeGitGrepIsStillAdvisedOnItsPattern() throws {
        #expect(try Self.call(#"git grep -n "func signedDelta" -- Sources/Trend.swift"#) == "digest Trend.signedDelta")
    }

    /// A command already reaching for sift needs no teaching, whatever rides alongside it.
    ///
    /// A real shape, paths shortened: a compound that leads with `sift digest`, which denied for the grep behind it would be advising sift to someone using sift.
    @Test
    func aCommandAlreadyInvokingSiftDrawsNoNudge() {
        #expect(ShellAdvice.suggestion(
            for: #"sift digest Sources/App 2>/dev/null | head -5; echo "---"; grep -rn "protocol Localizable" Sources/View.swift | head"#
        ) == nil)
        #expect(ShellAdvice.suggestion(
            for: #"/Users/dev/.local/bin/sift where Foo; grep -n "func bar" Sources/View.swift"#
        ) == nil)
    }

    /// Prose *about* a lookup is not a lookup: the verb sits inside a quoted argument.
    ///
    /// The shape of a `claude -p` prompt describing a grep, which a reading that finds verbs anywhere denies with `where claude`.
    @Test
    func aVerbInsideAQuotedArgumentIsNotACommandWord() {
        #expect(ShellAdvice.suggestion(
            for: #"claude -p --model haiku "First run this exact bash command yourself: grep -n func Thing.swift . Then reply DONE.""#
        ) == nil)
    }

    /// An escaped quote is a literal, not the end of the run — without the escape case, prose carrying one `\"` re-exposes everything after it, which is the same false positive the masking exists to close.
    @Test
    func anEscapedQuoteDoesNotEndTheMaskedRun() {
        #expect(ShellAdvice.suggestion(
            for: #"claude -p "note the \" character, then grep -n func Thing.swift is what we avoid""#
        ) == nil)
    }

    /// Only the command word exempts a command — a search *for* the word sift, or a `cd` into a directory named after it, is plausible in exactly the repo the tool is developed in, and going silent there opens the counted-but-never-advised divergence.
    @Test
    func theWordSiftInAPatternOrPathDoesNotExemptTheCommand() throws {
        #expect(try Self.call("grep -rn sift Sources/View.swift") == "where sift")
        #expect(try Self.call(#"cd /Users/dev/Developer/sift && grep -rn "func resolve" Sources/View.swift"#) == "where resolve")
    }

    /// A relative pathspec contains `..` and a backup file ends in `~`, and neither is a revision — a shape test loose enough to catch them deletes a legitimate working-tree search from the advisor and the audit at once.
    @Test
    func aRelativePathspecIsNotMistakenForARevision() throws {
        #expect(try Self.call(#"git grep -n "func signedDelta" ../Sources/Trend.swift"#) == "digest Trend.signedDelta")
    }

    /// A subshell wrapper shifts the verb into `(grep`, which must still anchor the operand parse — losing it degrades the advice to the generic form.
    ///
    /// The `)` closing the subshell ends the file's word, so the file is read as the one file the grep searches.
    @Test
    func aSubshellWrappedGrepKeepsItsOperands() throws {
        #expect(try Self.call(#"(grep -n "func signedDelta" /x/Trend.swift)"#) == "digest Trend.signedDelta")
    }

    /// The env-assignment prefix named as motivation for anchoring on the verb, pinned.
    @Test
    func anEnvAssignmentPrefixDoesNotShiftTheOperandParse() throws {
        #expect(try Self.call(#"LC_ALL=C grep -n "func signedDelta" /x/Trend.swift"#) == "digest Trend.signedDelta")
    }

    /// A sweep whose pattern names nothing at all is a search for text the index does not record.
    ///
    /// `grep -rn "0\.1\.0" Sources --include=*.swift` — a search for a version literal — must not be refused and offered the bare `search`, a call that cannot answer it.
    ///
    /// The bar is deliberately "names nothing", not "names no symbol". `final class` and `some View` name no symbol either and are exactly what `search` serves, so a rule drawn at the symbol would have silenced the tool's flagship case; and a pattern that *does* name something is ``SiftCore/AdvisableName``'s judgement, made through the predicate the scan uses too.
    @Test
    func aSweepWhosePatternNamesNothingIsATextSearch() {
        #expect(ShellAdvice.textSearchReason(#"grep -rn "0\.1\.0" Sources --include=*.swift"#, holdsSource: nil) != nil)
        #expect(ShellAdvice.textSearchReason(#"grep -rn "2026-09" Sources --include=*.swift"#, holdsSource: nil) != nil)
        #expect(ShellAdvice.textSearchReason(#"grep -rn -- "->" Sources --include=*.swift"#, holdsSource: nil) != nil)

        // Swift's own vocabulary is not nothing: these are shape questions, and `search` is the answer.
        #expect(ShellAdvice.textSearchReason(#"grep -rn "final class" Sources --include=*.swift"#, holdsSource: nil) == nil)
        #expect(ShellAdvice.textSearchReason(#"grep -rn "@Test func" Sources --include=*.swift"#, holdsSource: nil) == nil)
        // A name is somebody else's judgement, and the sweep for one is advised as it always was.
        #expect(ShellAdvice.textSearchReason(#"grep -rn "UsageWindow" Sources --include=*.swift"#, holdsSource: nil) == nil)
        // One file named is a digest of that file, whatever the pattern turns out to be.
        #expect(ShellAdvice.textSearchReason(#"grep -n "0\.1\.0" /x/Version.swift"#, holdsSource: nil) == nil)
    }

    /// The advisor still names the call, because the miss is real and the metric goes on counting it.
    ///
    /// What differs is who withholds it: an advisor that returned `nil` here would leave `TranscriptScan` scoring the command as a lookup the index lost while the hook had just judged it unanswerable, which moves the reported share in the pessimistic direction — the shape of disagreement `PreToolUseCommand.lookup` exists to prevent.
    @Test
    func theAdvisorStillNamesACallForASearchItDeclaresUnanswerable() throws {
        #expect(try Self.call(#"grep -rn "0\.1\.0" Sources --include=*.swift"#) == "search")
        #expect(try Self.call(#"grep -c "@Test func" /x/GuardedRuleTests.swift"#) == "digest GuardedRuleTests.Test")
    }

    /// The same sweep for a name the index could hold keeps its nudge — the rule tightens what is advised, not whether sweeps are.
    @Test
    func aSweepForASymbolIsStillAdvised() throws {
        #expect(try Self.call(#"grep -rn "UsageWindow" Sources --include=*.swift"#) == "where UsageWindow")
        #expect(try Self.call(#"grep -rn "func signedDelta" Sources --include=*.swift"#) == "where signedDelta")
    }

    /// A dotted member path is one target, and one of the commonest shapes anyone greps for.
    ///
    /// Reading `certain` as "one bare word" refuses `Type.member` outright — counted out of the classification, and, since the advisor asks the same question, refused a correct nudge as well. A capitalised `Type.member` is that path whether its dot is bare or escaped, since the grep asks where the member is written; a deeper path stands on its longest component.
    @Test
    func aDottedPathIsOneCertainTarget() {
        #expect(PatternReading.identifier(in: "CatalogueStore.append", certain: true) == "CatalogueStore.append")
        #expect(PatternReading.identifier(in: "Outer.Nested.member", certain: true) == "Nested")
        #expect(PatternReading.identifier(in: "UsageWindow", certain: true) == "UsageWindow")
        // A name is a Swift identifier in any script, and an emoji is not one.
        #expect(PatternReading.identifier(in: "Café", certain: true) == "Café")
        #expect(PatternReading.identifier(in: "Überblick.größe", certain: true) == "Überblick.größe")
        #expect(PatternReading.identifier(in: "func größe(", certain: false) == "größe")
        #expect(PatternReading.identifier(in: "Äpfel(", certain: false) == "Äpfel")
        #expect(PatternReading.identifier(in: "🦊", certain: true) == nil)
        #expect(PatternReading.namesNothing(in: "🦊"))
        #expect(!PatternReading.namesNothing(in: "é"))

        // And a name with punctuation on it is a marker in a comment, not a path.
        #expect(PatternReading.identifier(in: "TODO:", certain: true) == nil)
        #expect(PatternReading.identifier(in: "0 1 0", certain: true) == nil)
    }

    /// A phrase with a space in it is never certain, however much of it is Swift's own vocabulary.
    ///
    /// **This is the whole safety property, and without it wrong refusals rise by an order of magnitude.** Admitting `<keyword> <word>` — on the reasoning that `some View` is one name with context around it — admits `for now`, `do nothing`, `in progress`, `guard against`, `import order` and `catch block` too, because `keywords` holds fifty of the most English-looking words in the language. And because the strict reading decides `ShellQuery.readsSwift` through `PatternReading.namesOnly`, that widens *classification* and not only the bar it was aimed at: a comment sweep of the form `grep -rn "<phrase>" Sources` turns into a counted lookup and a live refusal.
    ///
    /// `some View` is the case that would be worth having and is not worth this. A nudge withheld costs one missed opportunity; nudges fired at English cost the mechanism's credibility, which is the currency every later refusal spends.
    ///
    /// One shape is deliberately absent from the list: `var name` reads as a *declaration* — the first of `identifier(in:certain:)`'s three rules, which names what follows a declaration keyword and is not subject to `certain`. That is a separate reading, and someone grepping `var name` plausibly is looking for the declaration.
    @Test
    func anEnglishPhraseIsNeverASwiftLookupHoweverSwiftItsWordsLook() {
        let phrases = [
            "for now", "do nothing", "in progress", "guard against", "catch block", "import order",
            "some day", "final answer", "if needed", "return early", "try again",
            "some View", "revisit this later", "not one of these words",
        ]
        for phrase in phrases {
            #expect(PatternReading.identifier(in: phrase, certain: true) == nil, "\(phrase) is prose")
            // And so the sweep that hunts for it is not classified as a lookup, which is the half that
            // reaches the metric as well as the hook.
            let command = #"grep -rn "\#(phrase)" Sources"#
            #expect(!ShellInspection.isSwiftLookup(command, holdsSource: { _ in true }), "\(phrase) is prose")
            #expect(ShellAdvice.suggestion(for: command, holdsSource: { _ in true }) == nil, "\(phrase) is prose")
            // And a sweep that *is* marked as Swift reads the same phrase as text, not as its longest word —
            // except `some View`, whose one word is a type's name.
            let reading = SweepPattern.reading(of: phrase)
            #expect(phrase == "some View" ? reading == .names(["View"]) : reading == .text, "\(phrase) is prose")
        }
    }

    /// A pattern beginning with `-` reaches the operand reader only behind `--`, and that is the spelling `grep` itself requires.
    ///
    /// `grep -rn "->" Sources` is not a working command — real `grep` reads `->` as an option and errors — so `--` is how the search is written, and eating it leaves `Sources` standing as the pattern and the command refused with `where Sources`. It is also the worked example in ``SiftMCP/ShellQuery/namesNothing(in:)``'s own documentation, which the reader must therefore be able to reach.
    @Test
    func aPatternBehindEndOfOptionsIsReadAsThePattern() {
        #expect(ShellQuery(#"grep -rn -- "->" Sources"#).pattern == "->")
        #expect(ShellAdvice.textSearchReason(#"grep -rn -- "->" Sources --include=*.swift"#, holdsSource: nil) != nil)
        // The `git grep` spelling puts *paths* behind `--`, because its pattern is already read by then.
        #expect(ShellQuery(#"git grep -n "func signedDelta" -- Sources/Trend.swift"#).pattern == "func signedDelta")
    }

    /// A short name is still a name, and a search for one is a lookup the index lost.
    ///
    /// `namesNothing` draws no length floor even though `identifier(in:certain:)` draws one at three characters, because the two answer different questions. Borrowing that floor would score `grep -rn "\bid\b" Sources` as a search the index could not have served, which takes it out of `TranscriptTally.total` and *raises* the reported share — the one direction the tally may never round.
    @Test
    func aShortNameKeepsItsSearchInTheDenominator() {
        #expect(!PatternReading.namesNothing(in: #"\bid\b"#))
        #expect(!PatternReading.namesNothing(in: "os"))
        #expect(ShellAdvice.textSearchReason(#"grep -rn "\bid\b" Sources --include=*.swift"#, holdsSource: nil) == nil)
        // What does name nothing is a pattern with no identifier in it at all.
        #expect(PatternReading.namesNothing(in: #"0\.1\.0"#))
        #expect(PatternReading.namesNothing(in: "2026-09"))
    }

    /// A count asks how much text there is, which is the one question a symbol index never answers.
    ///
    /// Take a lint rule whose tests are Swift source held inside triple-quoted string literals: `grep -c '@Test func'` over such a file counts the fixtures, and the `digest` offered instead resolves *declarations* — of which there are fewer, because a declaration inside a string literal is characters rather than a declaration. The replacement returns a different number, not the same number more cheaply.
    @Test
    func aCountIsATextSearch() throws {
        #expect(ShellAdvice.textSearchReason(#"grep -c "@Test func" /x/GuardedRuleTests.swift"#, holdsSource: nil) != nil)
        #expect(ShellAdvice.textSearchReason(#"grep -rc "func body" Sources --include=*.swift"#, holdsSource: nil) != nil)
        #expect(ShellAdvice.textSearchReason(#"rg --count "func body" /x/View.swift"#, holdsSource: nil) != nil)
        // Counted in a later stage of the pipeline than the one the advice would have been drawn from.
        #expect(ShellAdvice.textSearchReason("cat /x/View.swift | wc -l", holdsSource: nil) != nil)
        #expect(ShellAdvice.textSearchReason(#"grep -n "func body" /x/View.swift | wc -l"#, holdsSource: nil) != nil)

        // `-C` is context and `head -c` is a byte window; neither is a count. The context grep keeps the
        // member's suggestion, and is withheld by no rule: a member's declaration is the one context grep
        // the hook can answer outright, running it and handing that member's source back.
        #expect(try Self.call(#"grep -C 3 "func signedDelta" /x/Trend.swift"#) == "digest Trend.signedDelta")
        // The same file and the same context around a pattern that is *not* a declaration is withheld
        // instead, under `contextLines` — `NeverRefusedShapesTests` has both sides of that boundary.
        #expect(ShellAdvice.textSearchReason(#"grep -C 3 "func signedDelta" /x/Trend.swift"#, holdsSource: nil) == nil)
        #expect(!ShellQuery("head -c 900 /x/View.swift").counts)
    }

    /// A count is read off the pipeline the lookup is in, never off the whole line.
    ///
    /// `ShellSyntax.segments` splits on `|`, `;` and `&&` alike, so asking the question of every segment would let a count of an unrelated non-Swift file in one leg delete a genuine Swift lookup in the leg beside it — and a long compound line is a common shape for a command to take. `statements` first, then segments within, is the distinction `RunAdvice` already draws.
    @Test
    func aCountInAnotherLegDoesNotSilenceThisOne() throws {
        #expect(try Self.call(#"wc -l README.md && grep -rn "UsageWindow" Sources --include=*.swift"#) == "where UsageWindow")
        #expect(ShellAdvice.textSearchReason(#"wc -l README.md && grep -rn "UsageWindow" Sources --include=*.swift"#, holdsSource: nil) == nil)
        #expect(try Self.call(#"grep -n "func recover" /x/View.swift; echo done | wc -c"#) == "digest View.recover")
        #expect(ShellAdvice.textSearchReason(#"grep -n "func recover" /x/View.swift; echo done | wc -c"#, holdsSource: nil) == nil)
    }

    /// A listing is not a read: nothing here opens a file, so nothing here is a lookup the index lost.
    ///
    /// `ls` and `find` are not read verbs, and this is pinned because a rule this file gains later must not quietly re-admit them.
    @Test
    func aDirectoryListingDrawsNoNudge() {
        #expect(ShellAdvice.suggestion(for: "ls -R Sources") == nil)
        #expect(ShellAdvice.suggestion(for: "ls -la Sources/App/*.swift") == nil)
        #expect(ShellAdvice.suggestion(for: #"find Sources -name "*.swift""#) == nil)
        #expect(ShellAdvice.suggestion(for: #"find Sources -name "*.swift" | head -20"#) == nil)
    }

    /// A search of a log is not a Swift lookup, however much Swift its pattern spells.
    ///
    /// The pattern is what is looked for and the operands are what is looked in, so a test's file name hunted through a build log draws nothing — and the same pattern pointed at Swift source is advised on the file, as it always was.
    @Test
    func aSearchOfALogDrawsNoNudgeWhateverThePatternSpells() throws {
        #expect(ShellAdvice.suggestion(for: #"grep -n "CommentHistoryTests.swift:3[0-9]…" file.log"#) == nil)
        #expect(ShellAdvice.suggestion(for: #"grep -n "CommentHistoryTests.swift:3[0-9]\|failed" file.log"#) == nil)
        #expect(ShellAdvice.suggestion(for: "tail -200 build.log | grep CommentHistoryTests.swift") == nil)

        #expect(try Self.call("grep -n foo Sources/X.swift") == "digest X.foo")
        #expect(try Self.call("cat README.md Sources/App/View.swift") == "digest View")
    }

    /// A glob is never a file to digest.
    ///
    /// A pathspec or a shell glob naming Swift restricts a search to Swift source across every file it matches — the intent `--include=*.swift` spells as a flag — so the search is a sweep, advised on its pattern exactly as that twin is: a name is `where`, and a pattern naming nothing is a text search. A plain read of a glob is the module it reads, never the glob's stem. One file named outright is still that file.
    @Test
    func aSwiftGlobIsASweepNeverAFileToDigest() throws {
        let pathspec = "git grep -n -i \"…\" -- '*.md' '*.swift'"

        #expect(ShellAdvice.suggestion(for: pathspec)?.call.hasPrefix("digest") == false)
        #expect(ShellAdvice.textSearchReason(pathspec, holdsSource: nil) != nil)

        #expect(try Self.call("git grep -n UsageWindow -- '*.swift'") == "where UsageWindow")
        #expect(try Self.call(#"git grep -n "func signedDelta" -- 'Sources/*.swift'"#) == "where signedDelta")
        #expect(try Self.call("grep -n signedDelta Sources/App/*.swift") == "where signedDelta")
        #expect(try Self.call("cat Sources/App/*.swift") == "digest App")
        #expect(try Self.call("git grep -n signedDelta -- Sources/Trend.swift") == "digest Trend.signedDelta")

        // The call is built in one place for every surface, so the rule is held there.
        #expect(!IndexSuggestion.forLookup(symbol: nil, file: "*.swift").call.hasPrefix("digest"))
        #expect(!IndexSuggestion.forLookup(symbol: nil, file: ".swift").call.hasPrefix("digest"))
        #expect(IndexSuggestion.forLookup(symbol: "signedDelta", file: "Sources/*.swift").call == "where signedDelta")
    }

    /// A search is offered with its query or not as a call at all.
    ///
    /// A pattern made of Swift's declaration vocabulary is a shape question, and the call offered is the query that asks it. A query is a conjunction, so two kinds at once — `class func` is a class method — is not one. A pattern that is one short name is that name. What no index call answers — a phrase of ordinary words, or an alternation with one in it — yields `search` alone, which names nothing to run and is the hook's to withhold.
    @Test
    func aSearchIsOfferedWithTheQueryItsPatternStandsFor() throws {
        #expect(try Self.call(#"grep -rn "final class" Sources --include=*.swift"#) == "search kind:class modifier:final")
        #expect(try Self.call(#"git grep -n "static func" -- '*.swift'"#) == "search kind:func modifier:static")
        #expect(try Self.call(#"grep -rn "\basync throws\b" Sources --include=*.swift"#) == "search effect:async effect:throws")
        #expect(try Self.call(#"grep -rn "\bid\b" Sources --include=*.swift"#) == "where id")
        #expect(SweepPattern.reading(of: "class func") == .text)
        #expect(SweepPattern.reading(of: #"final class\|struct"#) == .text)
        #expect(SweepPattern.reading(of: "static let") == .shape("kind:var modifier:static sig:let"))
        #expect(SweepPattern.reading(of: "let") == .shape("kind:var sig:let"))

        let alternation = #"grep -rn -i "every response\|every answer" Docs Sources --include=*.md --include=*.swift"#
        let untargeted = try [
            #require(ShellAdvice.suggestion(for: alternation)),
            #require(ShellAdvice.suggestion(for: #"grep -rn "do it" Sources --include=*.swift"#)),
        ]
        #expect(untargeted.map(\.call) == ["search", "search"])
        #expect(untargeted.map(\.namesATarget) == [false, false])
        #expect(IndexSuggestion.forSweep(pattern: "final class").namesATarget)
        #expect(IndexSuggestion.forLookup(symbol: "UsageWindow", file: nil).namesATarget)
    }

    /// A branch that is only declaration syntax — no name in it, `name(of:)` reads `nil` for every one of them — has no name of its own, but it is not prose either, and it must never empty an alternation that carries a name beside it.
    ///
    /// On `main` these were refused as `untargeted`, with the lowercase name beside them dropped.
    @Test
    func declarationSyntaxBesideANameIsStillThatNamesLookup() throws {
        #expect(try Self.call(#"grep -rn "final class\|signedDelta" Sources --include=*.swift"#) == "where signedDelta")
        #expect(try Self.call(#"grep -rn "@Test func\|makePreview" Sources --include=*.swift"#) == "where makePreview")
        #expect(SweepPattern.reading(of: #"final class\|signedDelta"#) == .names(["signedDelta"]))
        #expect(SweepPattern.reading(of: #"@Test func\|makePreview"#) == .names(["makePreview"]))
        #expect(SweepPattern.reading(of: #"class .*Store\|signedDelta"#) == .names(["signedDelta"]))

        // Anchored, spaced by `\s*`, or opened by a modifier: the same form `InPlaceShape` reads, and a plain
        // lowercase name beside it — the one kind prose would drop — is kept.
        #expect(SweepPattern.reading(of: #"^final class\|save"#) == .names(["save"]))
        #expect(SweepPattern.reading(of: #"^\s*final class\|save"#) == .names(["save"]))
        #expect(SweepPattern.reading(of: #"mutating func\|reset"#) == .names(["reset"]))
        #expect(SweepPattern.reading(of: #"required init\|decode"#) == .names(["decode"]))
        #expect(SweepPattern.reading(of: #"open class\|save"#) == .names(["save"]))

        // Beside real prose the names stand, however code-shaped or anchored, with the prose kept as written: an
        // answer standing on the names covers one of the branches it was asked about and has to say which it leaves.
        #expect(SweepPattern.reading(of: #"stale gate\|signedDelta"#) == .partial(names: ["signedDelta"], prose: ["stale gate"]))
        #expect(SweepPattern.reading(of: #"stale gate\|\brounding\b"#) == .partial(names: ["rounding"], prose: ["stale gate"]))
        #expect(SweepPattern.reading(of: #"stale gate\|rounding"#) == .partial(names: ["rounding"], prose: ["stale gate"]))
        #expect(SweepPattern.reading(of: #"open question\|rounding"#) == .partial(names: ["rounding"], prose: ["open question"]))
    }

    /// A sweep stands on the strict reading of its pattern, because it has no one file to read a phrase against.
    ///
    /// A phrase of ordinary words names no symbol, so a Swift-filtered sweep for one offers no `where` for its longest word — which any index declaring that word would otherwise refuse the search on. One identifier is still that name, and one file named is still read on the loose reading, since there the file is the answer.
    @Test
    func aSweepForAPhraseStandsOnNoSymbol() throws {
        let phrase = try #require(ShellAdvice.suggestion(for: #"grep -rn --include=*.swift "stale index" Sources"#))

        #expect(phrase.symbol == nil)
        #expect(!phrase.namesATarget)
        #expect(try Self.call("grep -rn --include=*.swift UsageWindow Sources") == "where UsageWindow")
        #expect(try Self.call(#"grep -rn "Outer.Nested.member" Sources --include=*.swift"#) == "where Nested")
        #expect(try Self.call(#"grep -n "stale index" /x/Catalogue.swift"#) == "digest Catalogue.stale")
    }

    /// A file filter's value is its own, whether it is joined by `=` or stands as the next word — never the pattern.
    ///
    /// Read as the pattern, `*.swift` pushes the real one into the paths, and the sweep is neither advised nor counted. A filter that leaves Swift *out* is not a Swift filter in any spelling.
    @Test(arguments: [
        "grep --include '*.swift' -rn MyType Sources",
        #"grep -r --include "*.swift" -l "MyType" ."#,
        "grep -rn --include=*.swift MyType Sources",
        "rg -g '*.swift' MyType Sources",
        "rg --glob '*.swift' MyType Sources",
        "rg --iglob '*.SWIFT' MyType Sources",
        "rg -t swift MyType Sources",
        "rg --type swift MyType Sources",
        "rg -tswift MyType Sources",
    ])
    func aFileFilterIsReadInEverySpelling(command: String) throws {
        #expect(try Self.call(command) == "where MyType")
        #expect(ShellQuery(command).pattern == "MyType")
    }

    /// A flag takes a value only in the tool that gives it one: `grep -T` is an initial tab and `ag -t` all text, where `rg -T` and `rg -t` name types.
    @Test
    func aFlagTakesAValueOnlyInTheToolThatGivesItOne() throws {
        let holdsSource: (String) -> Bool = { $0 == "Sources" }

        for command in ["grep -T -rn MyType Sources", "grep -T MyType Sources", "ag -t MyType Sources"] {
            #expect(ShellQuery(command).pattern == "MyType", "\(command)")
            #expect(ShellInspection.isSwiftLookup(command, holdsSource: holdsSource), "\(command)")
            #expect(ShellAdvice.suggestion(for: command, holdsSource: holdsSource)?.call == "where MyType", "\(command)")
        }

        #expect(ShellQuery("rg -T md MyType Sources").pattern == "MyType")
        #expect(ShellQuery("rg -t swift MyType Sources").pattern == "MyType")
        #expect(try Self.call(#"ag -G '\.swift$' MyType Sources"#) == "where MyType")
        #expect(ShellQuery("git grep -t MyType -- Sources").pattern == "MyType")
    }

    /// A search that excludes Swift is not a Swift lookup, even over a tree that holds Swift: the exclusion has ruled out every file the index covers.
    @Test
    func anExclusionOfSwiftIsNotASwiftLookupOverAnyTree() throws {
        let root = try TemporaryDirectory.make("exclusion").appendingPathComponent("exclusion")
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: sources.appendingPathComponent("View.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ShellAdvice.suggestion(for: "grep -rn MyType --exclude='*.swift' Sources", in: root.path) == nil)
        #expect(ShellAdvice.suggestion(for: "rg -g '!*.swift' MyType Sources", in: root.path) == nil)
        #expect(!ShellInspection.isSwiftLookup("grep -rn MyType --exclude='*.swift' Sources", in: root.path))
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "MyType", "path": "Sources", "glob": "!*.swift"], in: root.path) == nil)
        // The same sweep with no exclusion is the lookup it always was.
        #expect(ShellAdvice.suggestion(for: "grep -rn MyType Sources", in: root.path)?.call == "where MyType")
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "MyType", "path": "Sources"], in: root.path)?.call == "where MyType")
    }

    /// The other side: a filter that excludes Swift names no Swift source to have searched.
    @Test(arguments: [
        "grep -rn --exclude '*.swift' MyType Sources",
        "grep -rn --exclude=*.swift MyType Sources",
        "rg -g '!*.swift' MyType Sources",
        "rg -T swift MyType Sources",
    ])
    func aFilterThatExcludesSwiftIsNotASwiftFilter(command: String) {
        #expect(ShellAdvice.suggestion(for: command) == nil)
    }

    /// An alternation is one `where` per name in it, and a branch of prose beside the names leaves the offer standing on them: the answer given in its place names the prose it does not cover.
    ///
    /// A comma list is not an alternation and draws no names: `UsageWindow, CatalogueStore` is the literal adjacency the search tool hunts, and a `where` for each name answers about each wherever it stands — a different question. It offers a bare `search`, which names nothing to run, so the hook withholds it as it withholds any phrase.
    @Test
    func anAlternationOffersItsNamesBesideProseToo() throws {
        #expect(try Self.call(#"grep -rn "UsageWindow\|stale index" Sources --include=*.swift"#) == "where UsageWindow")
        #expect(try Self.call(#"grep -rnE "UsageWindow|id" Sources --include=*.swift"#) == "where UsageWindow")
        #expect(try Self.call(#"grep -rn "UsageWindow, CatalogueStore" Sources --include=*.swift"#) == "search")
        #expect(try Self.call(#"grep -rn "every response\|every answer" Sources --include=*.swift"#) == "search")

        let seven = ["Depot", "Gizmo", "Orchard", "Catalogue", "UsageWindow", "UsageLog", "CatalogueStore"]
        let capped = try Self.call(#"grep -rn "\#(seven.joined(separator: #"\|"#))" Sources --include=*.swift"#)
        #expect(capped == (seven.prefix(5).map { "where \($0)" } + ["… and 2 more names left out"]).joined(separator: "\n"))
    }

    /// A read of several named files is several reads, one digest each; a read of a glob is the module the glob reads, or the overview.
    @Test
    func aReadOfSeveralFilesIsADigestOfEach() throws {
        #expect(try Self.call("cat Sources/App/Depot.swift Sources/App/Gizmo.swift") == "digest Depot\ndigest Gizmo")
        #expect(try Self.call("cat Sources/App/*.swift") == "digest App")
        #expect(try Self.call("head -50 Sources/App/*.swift") == "digest App")
        #expect(try Self.call("less Tests/SiftMCPTests/*Tests.swift") == "digest SiftMCPTests")
        #expect(try Self.call("cat *.swift") == "digest .")

        let files = (1 ... 7).map { "Sources/App/File\($0).swift" }
        let capped = try Self.call("cat \(files.joined(separator: " "))")
        #expect(capped == ((1 ... 5).map { "digest File\($0)" } + ["… and 2 more files left out"]).joined(separator: "\n"))
    }

    /// A short name alone is a name only when word-anchored, on either surface: unanchored, `x` matches inside every word holding it.
    @Test
    func aShortNameCountsOnlyWordAnchored() throws {
        #expect(try Self.call(#"grep -rn "\bid\b" Sources --include=*.swift"#) == "where id")
        #expect(try Self.call(#"grep -rn "\<id\>" Sources --include=*.swift"#) == "where id")
        #expect(try Self.call(#"grep -rn "\bid\b\|\bos\b" Sources --include=*.swift"#) == "where id\nwhere os")
        #expect(try Self.call(#"grep -rn "x" Sources --include=*.swift"#) == "search")
        #expect(try Self.call(#"grep -rn "id\|os" Sources --include=*.swift"#) == "search")
        #expect(try Self.call(#"grep -n "x" /x/Theme.swift"#) == "digest Theme")
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "x", "glob": "*.swift"])?.call == "search")
        #expect(SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": #"\bid\b"#, "glob": "*.swift"])?.call == "where id")
    }

    /// A bracket in a path is a directory's name as often as a character class, so it does not make the path a glob; a wildcard does.
    @Test
    func aBracketedDirectoryIsAPathNotAGlob() throws {
        #expect(try Self.call("grep -n foo 'Sources/App/[Old]/X.swift'") == "digest X.foo")
        #expect(!SwiftSourcePath.isGlob("Sources/App/[Old]/X.swift"))
        #expect(SwiftSourcePath.isGlob("Sources/App/*.swift"))
        #expect(SwiftSourcePath.isGlob("Sources/App/Vie?.swift"))
    }

    /// Text being *written* is not a file being read, however much of it is about code.
    ///
    /// The clearest case: a `gh issue create` refused and offered `search`, because the word `search` appears in the issue's own prose. The command opens no file. Every spelling a long body arrives in is covered here — a quoted argument, a heredoc, a substitution around one, a file the body is read from — because which one a caller reaches for is not something the caller should have to weigh.
    @Test
    func aCommandsPayloadIsNotAFileItReads() {
        #expect(ShellAdvice.suggestion(
            for: #"gh issue create --repo o/r --title "The nudge fires on payloads" --body "It suggested search instead of the grep of Sources/App/View.swift I asked for.""#
        ) == nil)
        #expect(ShellAdvice.suggestion(
            for: "gh issue create --repo o/r --body \"$(cat <<'EOF'\nit suggested search over grep -rn Foo Sources/App/View.swift\nEOF\n)\""
        ) == nil)
        #expect(ShellAdvice.suggestion(for: "gh issue create --repo o/r --body-file /tmp/body.md") == nil)
        #expect(ShellAdvice.suggestion(
            for: #"git commit -m "advise search rather than a grep of Sources/App/View.swift""#
        ) == nil)
    }
}

extension ShellAdviceTests {
    /// A line of several lookups is keyed on the first one the ledger has not already allowed, so a new lookup behind the re-run of an allowed one is its own ask — a window included — and where nothing is left the key is the first lookup's.
    @Test
    func aCompoundLineIsKeyedOnItsFirstLookupNotAlreadyAllowed() {
        let first = "grep -n Foo Sources/App/Depot.swift"
        let second = "grep -n Bar Sources/App/Gadget.swift"
        let line = "\(first) && \(second)"

        #expect(ShellAdvice.lookupKeys(for: line, holdsSource: nil) == [first, second])
        #expect(ShellAdvice.lookupKey(for: line, holdsSource: nil) == first)
        #expect(ShellAdvice.lookupKey(for: line, holdsSource: nil, skipping: [first]) == second)
        #expect(ShellAdvice.lookupKey(for: line, holdsSource: nil, skipping: [first, second]) == first)
        #expect(ShellAdvice.lookupKey(for: "\(first) && sed -n '1,30p' Sources/App/Gadget.swift", holdsSource: nil, skipping: [first]) == "sed -n '1,30p' Sources/App/Gadget.swift")
        #expect(ShellAdvice.lookupKey(for: first, holdsSource: nil, skipping: [first]) == first)
    }

    /// Every fact the hook draws from a line — the suggestion, the path it names, the text-search reason — is drawn from the lookup it is keyed on, never from the allowed one in front of it.
    @Test
    func aCompoundLinesAdviceIsAboutTheLookupItIsKeyedOn() throws {
        let first = "grep -n Foo Sources/App/Depot.swift"
        let line = "\(first) && grep -n Bar Sources/App/Gadget.swift"
        let counting = "\(first) && grep -c Bar Sources/App/Gadget.swift"

        let about = try #require(ShellAdvice.suggestion(for: line, holdsSource: nil, skipping: [first])).call

        #expect(about.contains("Gadget") && !about.contains("Depot"))
        #expect(try #require(ShellAdvice.suggestion(for: line, holdsSource: nil)).call.contains("Depot"))
        #expect(ShellAdvice.namedPath(for: line, holdsSource: nil, skipping: [first]) == "Sources/App/Gadget.swift")
        #expect(ShellAdvice.textSearchReason(counting, holdsSource: nil) == nil)
        #expect(ShellAdvice.textSearchReason(counting, holdsSource: nil, skipping: [first]) != nil)
    }
}
