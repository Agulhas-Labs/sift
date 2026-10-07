//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// The hook and the metric answer one question, on both search surfaces.
///
/// **This is the invariant a suppression is easiest to break and hardest to notice breaking.** A gate that silences the hook and leaves the scan counting the command as a lookup the index lost moves the reported share *down* for exactly the searches the tool has just judged unanswerable — and every test of the advisor still passes, because the advisor is not where the number comes from. `PreToolUseCommand.lookup` names the same hazard: saying so in one place while counting it in the other makes the share an argument with itself.
///
/// So each rule is pinned twice over — the hook withholding it, and the tally scoring it out of the share — and once on each surface, because which tool a caller reaches for may not change the answer.
@Suite(.temporaryDirectories)
struct AdviceAgreementTests {
    private static func bash(_ command: String) -> Data {
        TranscriptFixture.toolUse("Bash", input: ["command": command])
    }

    private static func hookLookup(
        _ payload: [String: Any],
        noting log: SuppressionLog,
        couldAnswer: @escaping (String) -> Bool = { _ in true }
    ) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(command: nil, payload: payload, in: nil, noting: log) { name, _ in couldAnswer(name) }
    }

    /// A count is withheld by the hook and counted out of the share, not counted against the index.
    @Test
    func aCountIsWithheldAndScoredAsATextSearch() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": #"grep -c "@Test func" /x/GuardedRuleTests.swift"#],
        ]
        #expect(Self.hookLookup(payload, noting: recording.log) == nil)
        #expect(recording.rules == ["textSearch"])

        let tally = TranscriptFixture.tally([Self.bash(#"grep -c "@Test func" /x/GuardedRuleTests.swift"#)])
        #expect(tally.textSearches == 1)
        #expect(tally.cold == 0)
        // Out of the denominator entirely: a search the tool declined to claim it could serve is not a
        // lookup the index lost, and leaving it in lowers the share every time a gate fires.
        #expect(tally.total == 0)
    }

    /// The same for a sweep whose pattern names nothing the index could hold.
    @Test
    func aSweepNamingNothingIsWithheldAndScoredAsATextSearch() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": #"grep -rn "0\.1\.0" Sources --include=*.swift"#],
        ]
        #expect(Self.hookLookup(payload, noting: recording.log) == nil)
        #expect(recording.rules == ["textSearch"])

        let tally = TranscriptFixture.tally([Self.bash(#"grep -rn "0\.1\.0" Sources --include=*.swift"#)])
        #expect(tally.textSearches == 1)
        #expect(tally.total == 0)
    }

    /// A retry that changes only what rides beside the grep is the same ask at both ends.
    ///
    /// The hook remembers a refused lookup by its reading stage — pattern, flags, paths (`ShellAdvice.lookupKey`) — so the `echo` label a session prints between steps does not make a new question of it, and the re-run it promised is allowed. A scan still keying on the whole line finds no refusal to match, scores that sanctioned re-run cold, and reports the mechanism working as defiance: the share falls by exactly the amount the hook succeeded.
    @Test
    func aRetryThatChangesOnlyTheLabelBesideTheGrepIsTheSameAskAtBothEnds() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let first = #"echo "=== a ==="; grep -rn "UsageWindow" Sources --include=*.swift"#
        let second = #"echo "=== b ==="; grep -rn "UsageWindow" Sources --include=*.swift"#
        let payload: (String) -> [String: Any] = { ["tool_name": "Bash", "tool_input": ["command": $0]] }

        let keys = [first, second].map { Self.hookLookup(payload($0), noting: recording.log)?.key }
        #expect(keys[0] != nil)
        #expect(keys[0] == keys[1])

        let tally = TranscriptFixture.tally([
            Self.bash(first),
            TranscriptFixture.toolResult(id: "t1", isError: true, text: TranscriptFixture.refusal(), bareText: true),
            Self.bash(second),
        ])
        // On the worth half: the hook refused the first because an index call answered it, so the re-run
        // it allowed is a lookup the index could have served, not text it never recorded.
        #expect(tally.withheldOnWorth == 1)
        #expect(tally.cold == 0)
    }

    /// A sweep for a name is untouched by any of it — refused as it always was, and counted as the miss it is.
    @Test
    func aSweepForANameIsStillRefusedAndStillCounted() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": #"grep -rn "UsageWindow" Sources --include=*.swift"#],
        ]
        #expect(Self.hookLookup(payload, noting: recording.log)?.suggestion.call == "where UsageWindow")
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(#"grep -rn "UsageWindow" Sources --include=*.swift"#)])
        #expect(tally.textSearches == 0)
        #expect(tally.cold == 1)
    }

    /// The `Grep` tool asks the identical questions and must meet the identical answers.
    ///
    /// Both cases are the rule's own: the count over a rule-test file whose Swift lives in string literals, and the version-literal sweep. A refusal at the shell that is silent here teaches a model where to go to avoid the refusal, which is the detour `SearchToolAdvice` exists to close.
    @Test
    func theGrepSurfaceReachesTheSameVerdictAsItsShellTwin() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let count: [String: Any] = [
            "pattern": "@Test func", "path": "/x/GuardedRuleTests.swift", "output_mode": "count",
        ]
        let literal: [String: Any] = ["output_mode": "content", "pattern": #"0\.1\.0"#, "glob": "*.swift"]

        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: count) != nil)
        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: literal) != nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": count], noting: recording.log) == nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": literal], noting: recording.log) == nil)
        #expect(recording.rules == ["textSearch", "textSearch"])

        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Grep", id: "g1", input: count),
            TranscriptFixture.toolUse("Grep", id: "g2", input: literal),
        ])
        #expect(tally.textSearches == 2)
        #expect(tally.total == 0)
    }

    /// A shape question is not one of these, on either surface: `search` is precisely what answers it.
    @Test
    func aShapeQuestionIsNotATextSearchOnEitherSurface() {
        #expect(ShellAdvice.textSearchReason(#"grep -rn "final class" Sources --include=*.swift"#, holdsSource: nil) == nil)
        #expect(SearchToolAdvice.textSearchReason(
            tool: "Grep",
            input: ["output_mode": "content", "pattern": "final class", "glob": "**/*.swift"]
        ) == nil)
        // And a `Glob` never is: it asks which files exist, which the repo overview answers outright.
        #expect(SearchToolAdvice.textSearchReason(tool: "Glob", input: ["pattern": "**/*.swift"]) == nil)
    }

    /// The gate-leg rule silences the hook, so it is counted even though no share could ever count it.
    ///
    /// A toolchain run is a *write* to `ShellInspection` and sits in no denominator, so nothing about it can disagree with the metric — but the fire rate is then the only evidence there will be that the rule is not over-firing, which is exactly what the suppression log exists for.
    @Test
    func aSilencedGateLegIsRecordedEvenThoughNoShareCountsIt() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let leg: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build"],
        ]
        #expect(Self.hookLookup(leg, noting: recording.log) == nil)
        #expect(recording.rules == ["gateLeg"])

        // A toolchain run nothing had to say about is not this rule firing, and writes no line.
        let quiet: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "sift run -- swift test"]]
        #expect(Self.hookLookup(quiet, noting: recording.log) == nil)
        #expect(recording.rules == ["gateLeg"])
    }

    /// A build already redirected to a log of its own is a gate leg by the same reasoning, and is counted like one.
    ///
    /// Withheld without a line — recording only the two `xcodebuild` actions — the redirect half of the rule would fire at a rate nothing could see. A pipe is not a leg — the caller is trimming the output, not keeping it — and nor is a redirect inside a script being written, which no rule of this one's silences.
    @Test
    func aBuildRedirectedToItsOwnLogIsRecordedAsAGateLeg() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let shell: (String) -> [String: Any] = { command in ["tool_name": "Bash", "tool_input": ["command": command]] }

        #expect(Self.hookLookup(shell("swift test > /tmp/test.log"), noting: recording.log) == nil)
        #expect(Self.hookLookup(shell("xcodebuild -scheme Gizmo test &> build.log"), noting: recording.log) == nil)
        #expect(recording.rules == ["gateLeg", "gateLeg"])

        #expect(Self.hookLookup(shell("swift test 2>&1 | tail -40"), noting: recording.log) == nil)
        #expect(Self.hookLookup(shell("cat > verify.sh <<'EOF'\nswift build > build.log\nEOF"), noting: recording.log) == nil)
        #expect(recording.rules == ["gateLeg", "gateLeg"])
    }

    /// Only standard output kept in a file is a log of its own, and only a redirect the line is judged as far as.
    ///
    /// Every one of these is silenced — each redirects or pipes a build — but none is the gate-leg rule firing: stderr alone and `/dev/null` keep no log to read, whichever order the streams are sent there in, and in the compound the pipe in the first statement silences the whole line before the second is judged, which is the order `suggestion` reads it in. Counting them as legs inflated the one rate the suppression log exists to keep honest. The controls are the other side: each keeps standard output in a file, in a different spelling — and in the compound a wrappable first statement is read past, and the redirect after it is the leg.
    @Test
    func onlyStandardOutputKeptInAFileIsAGateLegAndOnlyWhereTheLineStops() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let shell: (String) -> [String: Any] = { command in ["tool_name": "Bash", "tool_input": ["command": command]] }

        let silencedElsewhere = [
            "swift build 2>/dev/null", "swift test > /dev/null", "swift test 2> err.txt", "swift build >/dev/null 2>&1", "swift test &>/dev/null",
            "swift build 2>&1 | tail -5; swift test > t.log", "swift build 2>/dev/null >& 2",
        ]
        let afterEach = silencedElsewhere.map { command in
            (command: command, silent: Self.hookLookup(shell(command), noting: recording.log) == nil, recorded: recording.rules.count)
        }
        let controls = ["swift build && swift test > t.log", "swift build >> build.log", "swift test 1> t.log", "swift build 2>&1 >out.log"]
        let controlsSilent = controls.map { command in
            (command: command, silent: Self.hookLookup(shell(command), noting: recording.log) == nil)
        }

        for control in controlsSilent {
            #expect(control.silent, "\(control.command) draws no nudge")
        }
        #expect(recording.rules == Array(repeating: "gateLeg", count: controls.count))
        for outcome in afterEach {
            #expect(outcome.silent, "\(outcome.command) draws no nudge")
            #expect(outcome.recorded == 0, "\(outcome.command) is not a gate leg")
        }
    }

    /// A search of a log is no lookup at either end, whatever Swift its pattern spells: the hook has nothing to withhold and the share nothing to count.
    @Test
    func aSearchOfALogIsNeitherRefusedNorCounted() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let command = #"grep -n "CommentHistoryTests.swift:3[0-9]…" file.log"#
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.total == 0)
        #expect(tally.textSearches == 0)
    }

    /// A pathspec restricting a search to Swift is judged like its `--include` twin: a pattern naming nothing is withheld by the hook and counted out of the share.
    @Test
    func aSwiftPathspecSweepIsJudgedLikeItsIncludeTwin() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let command = "git grep -n -i \"…\" -- '*.md' '*.swift'"
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(recording.rules == ["textSearch"])

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.textSearches == 1)
        #expect(tally.total == 0)
    }

    /// A refusal offers a call that can be made, or none: a bare `search` is withheld, logged, and scored out of the share on the same property.
    ///
    /// An alternation or a phrase of short words has no one call that answers it, on either surface. A shape question and a short name are not that — each is offered with the call that asks it, and counted as the miss it is.
    @Test
    func anUntargetedSuggestionIsWithheldAndScoredAsATextSearch() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let shell: (String) -> [String: Any] = { command in ["tool_name": "Bash", "tool_input": ["command": command]] }
        let alternation = #"grep -rn -i "every response\|every answer" Docs Sources --include=*.md --include=*.swift"#
        let grep: [String: Any] = ["output_mode": "content", "pattern": #"every response\|every answer"#, "glob": "*.swift"]

        #expect(Self.hookLookup(shell(alternation), noting: recording.log) == nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": grep], noting: recording.log) == nil)
        #expect(recording.rules == ["untargeted", "untargeted"])
        let tally = TranscriptFixture.tally([
            Self.bash(alternation), TranscriptFixture.toolUse("Grep", id: "g1", input: grep),
        ])
        #expect(tally.textSearches == 2)
        #expect(tally.total == 0)

        let shape = #"grep -rn "final class" Sources --include=*.swift"#
        let shortName = #"grep -rn "\bid\b" Sources --include=*.swift"#
        #expect(Self.hookLookup(shell(shape), noting: recording.log)?.suggestion.call == "search kind:class modifier:final")
        #expect(Self.hookLookup(shell(shortName), noting: recording.log)?.suggestion.call == "where id")
        #expect(recording.rules.count == 2)
        #expect(TranscriptFixture.tally([Self.bash(shape), Self.bash(shortName)]).cold == 2)
    }

    /// A Swift-filtered sweep for a phrase is not refused on its longest word, on either surface, and is counted out of the share; a sweep for one name is refused and counted as it always was.
    ///
    /// The phrase's words are ones an index could well declare, and outside any repository every name is taken to be answerable — which is exactly where a guess at the longest word would have been refused on.
    @Test
    func aSweepForAPhraseIsNotRefusedOnItsLongestWord() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let phrase = #"grep -rn --include=*.swift "stale index" Sources"#
        let grep: [String: Any] = ["output_mode": "content", "pattern": "stale index", "glob": "*.swift"]

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": phrase]], noting: recording.log) == nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": grep], noting: recording.log) == nil)
        let tally = TranscriptFixture.tally([Self.bash(phrase), TranscriptFixture.toolUse("Grep", id: "g1", input: grep)])
        #expect(tally.textSearches == 2)
        #expect(tally.total == 0)

        let name = "grep -rn --include=*.swift UsageWindow Sources"
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": name]], noting: recording.log)?.suggestion.call == "where UsageWindow")
        #expect(TranscriptFixture.tally([Self.bash(name)]).cold == 1)
    }

    /// A sweep whose file filter stands as a separate word is refused and counted as the miss it is, like its `=` twin.
    @Test
    func aSeparatedFileFilterIsRefusedAndCounted() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        for command in ["grep --include '*.swift' -rn MyType Sources", "rg -g '*.swift' MyType Sources"] {
            #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where MyType")
            #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
        }

        #expect(recording.rules.isEmpty)
    }

    /// A sweep is withheld and scored as a text search only when no index call answers it — on both surfaces, and at both ends.
    ///
    /// One name among Swift's own words and punctuation is `where` for it; a shape is the `search` query that asks it; an alternation of names is one `where` per name. Each of those is refused and counted as the miss it is. Only a phrase of ordinary words, or an alternation with one in it, is withheld — and then the metric scores it out of the share on the same verdict. The `Grep` spelling is the regex a `Grep` call would carry for the same search, so `UsageWindow?` in `grep` and `UsageWindow\?` in `Grep` are one question.
    @Test(arguments: [
        Sweep(": UsageWindow", ": UsageWindow", "where UsageWindow"),
        Sweep("UsageWindow?", #"UsageWindow\?"#, "where UsageWindow"),
        Sweep("UsageWindow {", #"UsageWindow \{"#, "where UsageWindow"),
        Sweep("class .*Store", "class .*Store", "search kind:class name:Store"),
        Sweep("@Observable", "@Observable", "search attr:Observable"),
        Sweep("@Test func", "@Test func", "search attr:Test kind:func"),
        Sweep("Task {", #"Task \{"#, "where Task"),
        Sweep(#"\.task {"#, #"\.task \{"#, "where task"),
        Sweep("try!", "try!", "search has:forceTry"),
        Sweep("static let", "static let", "search kind:var modifier:static sig:let"),
        Sweep("private let", "private let", "search kind:var modifier:private sig:let"),
        Sweep("static var", "static var", "search kind:var modifier:static"),
        Sweep("final class", "final class", "search kind:class modifier:final"),
        Sweep(#"\bid\b"#, #"\bid\b"#, "where id"),
        Sweep(#"UsageWindow\|UsageLog"#, "UsageWindow|UsageLog", "where UsageWindow\nwhere UsageLog"),
        Sweep("stale index", "stale index", nil),
        Sweep(#"every response\|every answer"#, "every response|every answer", nil),
    ])
    func aSweepIsWithheldOnlyWhenNoIndexCallAnswersIt(sweep: Sweep) throws {
        let (shell, grep, call) = (sweep.shell, sweep.grep, sweep.call)
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn --include=*.swift "\#(shell)" Sources"#
        let input: [String: Any] = ["output_mode": "content", "pattern": grep, "glob": "*.swift"]

        let refusals = [
            Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log),
            Self.hookLookup(["tool_name": "Grep", "tool_input": input], noting: recording.log),
        ]
        let tally = TranscriptFixture.tally([Self.bash(command), TranscriptFixture.toolUse("Grep", id: "g1", input: input)])

        #expect(refusals.map { $0?.suggestion.call } == [call, call])
        #expect(tally.textSearches == (call == nil ? 2 : 0))
        #expect(tally.cold == (call == nil ? 0 : 2))
        #expect(recording.rules.count == (call == nil ? 2 : 0))
    }

    /// A phrase of one long word and an English one is a phrase, on both surfaces and at both ends — withheld, and scored out of the share.
    @Test(arguments: [
        "for now", "in progress", "is empty", "by default", "import order", "set up", "fix it", "try again",
        "so far", "return early", "do nothing", "some day", "final answer", "guard against",
    ])
    func aPhraseWithOneLongWordIsWithheldAsText(phrase: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn --include=*.swift "\#(phrase)" Sources"#
        let input: [String: Any] = ["output_mode": "content", "pattern": phrase, "type": "swift"]

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": input], noting: recording.log) == nil)
        #expect(recording.rules == ["untargeted", "untargeted"])
        #expect(TranscriptFixture.tally([Self.bash(command), TranscriptFixture.toolUse("Grep", id: "g1", input: input)]).textSearches == 2)
    }

    /// Swift-shaped context carries the same lowercase name: a colon, a declaration keyword, a member dot.
    @Test(arguments: [": order", "var order", ".order", "order:", "order?", "order {"])
    func aNameInSwiftShapedContextIsStillALookup(pattern: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn --include=*.swift "\#(pattern)" Sources"#
        let input: [String: Any] = ["output_mode": "content", "pattern": pattern, "type": "swift"]

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where order")
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": input], noting: recording.log)?.suggestion.call == "where order")
        #expect(TranscriptFixture.tally([Self.bash(command), TranscriptFixture.toolUse("Grep", id: "g1", input: input)]).cold == 2)
    }

    /// `-w` anchors a pattern to whole words exactly as `\b…\b` does, so a short name searched with it is that name — refused, and counted as the miss it is.
    @Test(arguments: ["grep -rnw id Sources --include=*.swift", "rg -w id -t swift Sources", "grep -rn --word-regexp id Sources --include=*.swift"])
    func aWordAnchoredShortNameIsALookup(command: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where id")
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    /// Wrapped in any command that runs what follows, a lookup is still refused and counted — only a printer's words are not one.
    @Test(arguments: ["watch -n 2", "ionice -c3", "caffeinate", "unbuffer", "sudo -n"])
    func aWrappedLookupIsStillRefusedAndCounted(wrapper: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = "\(wrapper) grep -rn UsageWindow Sources --include=*.swift"

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where UsageWindow")
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    /// A refusal offers one `where` per name only where every name is declared; an alternation the index can speak for part of is withheld whole, and scored out of the share rather than counted as a miss.
    ///
    /// The ask was three names, so advice for two of them answers a question nobody asked. Withholding it costs nothing — the search runs — where offering it spends a round trip on an answer that cannot cover the command.
    @Test
    func anAlternationOnlyPartlyDeclaredIsWithheld() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn "UsageWindow\|Ghost\|UsageLog" Sources --include=*.swift"#
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
        let declared: (String) -> Bool = { $0 != "Ghost" }

        // Every name declared: the whole ask is answered, one `where` per name, and counted as the miss it is.
        #expect(Self.hookLookup(payload, noting: recording.log)?.suggestion.call == "where UsageWindow\nwhere Ghost\nwhere UsageLog")
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)

        // One name undeclared: nothing is offered, under a rule of its own, and the tally scores it out of the share.
        #expect(Self.hookLookup(payload, noting: recording.log, couldAnswer: declared) == nil)
        #expect(recording.rules == ["partlyDeclared"])
        let partly = TranscriptFixture.tally([Self.bash(command)], couldAnswer: { name, _ in declared(name) })
        // The index declares some of these names and answers one `where` apiece, so what was weighed was
        // the cost of asking: the worth half, kept apart from the names it declares nothing for below.
        #expect(partly.withheldOnWorth == 1)
        #expect(partly.cold == 0)
        #expect(partly.total == 0)

        // None declared: the older rule, which measures something else and keeps its own name.
        #expect(Self.hookLookup(payload, noting: recording.log) { _ in false } == nil)
        #expect(recording.rules == ["partlyDeclared", "unknownName"])
        #expect(TranscriptFixture.tally([Self.bash(command)], couldAnswer: { _, _ in false }).textSearches == 1)
    }

    /// The same alternation confined to one file is not this rule's business: it is withheld a rule earlier, on the arithmetic of one call per name against one grep, whatever the names are declared.
    @Test
    func anAlternationOnOneFileIsWithheldBeforeTheNamesAreJudged() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -n "UsageWindow\|Ghost" Sources/App/UsageWindow.swift"#
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]

        #expect(Self.hookLookup(payload, noting: recording.log, couldAnswer: { $0 != "Ghost" }) == nil)
        #expect(recording.rules == ["severalNames"])
        #expect(TranscriptFixture.tally([Self.bash(command)]).total == 0)
    }

    /// A read of several named files, or of a glob of them, is refused with the digests that answer it and counted as the miss it is — as main counted it.
    @Test(arguments: ["cat Sources/App/Depot.swift Sources/App/Gizmo.swift", "cat Sources/App/*.swift", "head -50 Sources/App/*.swift"])
    func aReadOfSeveralFilesIsRefusedAndCounted(command: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call.hasPrefix("digest ") == true)
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).cold == 1)
    }

    /// Leaving *some* Swift out of a sweep still searches the rest of it, so the sweep is refused and counted as the miss it is; only leaving all of it out makes it no lookup.
    @Test
    func aPartialExclusionOfSwiftIsStillALookupAtBothEnds() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let root = try TemporaryDirectory.make("partial-exclusion").appendingPathComponent("partial-exclusion")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: root.appendingPathComponent("Sources/View.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let line: (String, [String: Any]) -> Data = { tool, input in
            let object: [String: Any] = [
                "type": "assistant", "cwd": root.path,
                "message": ["content": [["type": "tool_use", "id": "t1", "name": tool, "input": input]]],
            ]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let lookup: (String, [String: Any]) -> PreToolUseCommand.Lookup? = { tool, input in
            Self.treeLookup(tool: tool, input: input, in: root, noting: recording.log)
        }
        let partial: [(String, [String: Any])] = [
            ("Bash", ["command": "grep -rn MyType --exclude='*Tests.swift' Sources"]),
            ("Bash", ["command": "grep -rn MyType --exclude=Package.swift Sources"]),
            ("Bash", ["command": "grep -rn MyType --exclude-dir=.swiftpm Sources"]),
            ("Bash", ["command": "rg -g '!*Tests.swift' MyType Sources"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "glob": "!*Tests.swift"]),
        ]
        let whole: [(String, [String: Any])] = [
            ("Bash", ["command": "grep -rn MyType --exclude='*.swift' Sources"]),
            ("Bash", ["command": "rg -g '!**/*.swift' MyType Sources"]),
            ("Bash", ["command": "rg -g '!*.{swift,md}' MyType Sources"]),
            ("Bash", ["command": "rg -T swift MyType Sources"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "glob": "!*.swift"]),
        ]

        for (tool, input) in partial {
            #expect(lookup(tool, input)?.suggestion.call == "where MyType", "\(input)")
            #expect(TranscriptFixture.tally([line(tool, input)]).cold == 1, "\(input)")
        }
        for (tool, input) in whole {
            #expect(lookup(tool, input) == nil, "\(input)")
            #expect(TranscriptFixture.tally([line(tool, input)]).total == 0, "\(input)")
        }

        #expect(recording.rules.isEmpty)
    }

    /// A name no index declares is still a text search at the metric's end, as `AdvisableName` withholds it at the hook's — and an alternation with only some of its names declared is withheld on worth instead, since the offer the hook would make is one call per name; only when none of its names is declared does it fall back to a text search.
    @Test
    func anUndeclaredNameIsATextSearchAndAnAlternationWithSomeNamesDeclaredIsWithheldOnWorth() {
        let task = Self.bash(#"grep -rn --include=*.swift "Task {" Sources"#)
        let pair = Self.bash(#"grep -rn --include=*.swift "UsageWindow\|UsageLog" Sources"#)

        #expect(TranscriptFixture.tally([task], couldAnswer: { _, _ in false }).textSearches == 1)
        #expect(TranscriptFixture.tally([pair]).cold == 1)
        #expect(TranscriptFixture.tally([pair], couldAnswer: { name, _ in name == "UsageLog" }).withheldOnWorth == 1)
        #expect(TranscriptFixture.tally([pair], couldAnswer: { _, _ in false }).textSearches == 1)
    }

    /// A regex left where a target belongs offers no call: the hook withholds it as untargeted, and the scan scores it out of the share on the same property.
    @Test
    func aRegexInATargetsPlaceIsWithheldAndScoredAsATextSearch() throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        let command = #"cat '[A-Za-z0-9_]+\.swift'"#
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(recording.rules == ["untargeted"])

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.textSearches == 1)
        #expect(tally.total == 0)
    }

    /// The parity claim, tested on the one pattern that made it false.
    ///
    /// `->` is `namesNothing`'s own worked example, and an operand reader that takes the pattern for a flag refuses the command with `where Sources` while the `Grep` twin stays silent. Written here in the spelling `grep` itself requires, which is what the reader honours.
    @Test
    func theSurfacesAgreeOnAPatternMadeOnlyOfPunctuation() {
        #expect(ShellAdvice.textSearchReason(#"grep -rn -- "->" Sources --include=*.swift"#, holdsSource: nil) != nil)
        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: ["output_mode": "content", "pattern": "->", "glob": "*.swift"]) != nil)
    }
}

/// The same suite, continued: what a file filter picking only other kinds of file does to a search.
extension AdviceAgreementTests {
    /// A search whose file filter picks only other kinds of file is not of Swift source, so neither end treats it as a lookup — even over a tree that holds Swift, where the directory probe would otherwise count it.
    ///
    /// The other side of the same rule: an inclusion that picks Swift beside something else still searches the Swift, and stays the refused, counted lookup it was. So does a glob that could still match a Swift file.
    @Test
    func anInclusionOfOnlyOtherFilesIsNoLookupAtBothEnds() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let root = try TemporaryDirectory.make("inclusion").appendingPathComponent("inclusion")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: root.appendingPathComponent("Sources/View.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let line: (String, [String: Any]) -> Data = { tool, input in
            let object: [String: Any] = [
                "type": "assistant", "cwd": root.path,
                "message": ["content": [["type": "tool_use", "id": "t1", "name": tool, "input": input]]],
            ]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let lookup: (String, [String: Any]) -> PreToolUseCommand.Lookup? = { tool, input in
            Self.treeLookup(tool: tool, input: input, in: root, noting: recording.log)
        }
        let otherFiles: [(String, [String: Any])] = [
            ("Bash", ["command": "grep -rn --include='*.jsonl' MyType Sources"]),
            ("Bash", ["command": "grep -rn --include='*.md' MyType Sources"]),
            ("Bash", ["command": "grep -rn --include '*.json' --include=*.md MyType Sources"]),
            ("Bash", ["command": "rg -t md MyType Sources"]),
            ("Bash", ["command": "rg -g '**/*.{json,md}' MyType Sources"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "glob": "*.json"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "type": "md"]),
        ]
        let stillSwift: [(String, [String: Any])] = [
            ("Bash", ["command": "grep -rn --include='*.swift' --include='*.md' MyType Sources"]),
            ("Bash", ["command": "grep -rn --include='*Tests*' MyType Sources"]),
            ("Bash", ["command": "rg -t md -g '*View*' MyType Sources"]),
            ("Bash", ["command": "rg --type-add 'docs:*.swift' -t docs MyType Sources"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "glob": "*.{swift,md}"]),
            ("Grep", ["output_mode": "content", "pattern": "MyType", "path": "Sources", "glob": "*View*", "type": "md"]),
        ]

        for (tool, input) in otherFiles {
            #expect(lookup(tool, input) == nil, "\(input)")
            #expect(TranscriptFixture.tally([line(tool, input)]).total == 0, "\(input)")
        }
        for (tool, input) in stillSwift {
            #expect(lookup(tool, input)?.suggestion.call == "where MyType", "\(input)")
            #expect(TranscriptFixture.tally([line(tool, input)]).cold == 1, "\(input)")
        }

        #expect(recording.rules.isEmpty)
    }
}

/// The same suite, continued: file names outside ASCII, and with spaces in them.
extension AdviceAgreementTests {
    /// Swift files whose names a stricter pattern would not have taken for names — a letter outside ASCII at the end, at the start, and a space — each with the call that serves it.
    static let unusualFileNames = [
        ("Sources/App/Café.swift", "digest Café"),
        ("Sources/App/Über.swift", "digest Über"),
        ("Sources/App/Foo Bar.swift", "digest /x/Sources/App/Foo Bar.swift"),
    ]

    /// A whole read of each is refused with the digest that serves it, and counted as the miss it is.
    ///
    /// The hook read file names by an ASCII-only pattern and let these reads through unrefused, while the scan counted every one of them against the index: a miss the metric could see and the hook never raised. A name is a Swift identifier in any script, and a name with a space in it is asked for by the path.
    @Test(arguments: unusualFileNames)
    func aWholeReadOfAnyNamedFileIsRefusedAndCountedAtBothEnds(file: String, call: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let path = "/x/" + file

        let lookup = Self.hookLookup(["tool_name": "Read", "tool_input": ["file_path": path]], noting: recording.log)
        #expect(lookup?.suggestion.call == call)
        #expect(lookup?.suggestion.namesATarget == true)
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Read", input: ["file_path": path])])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A `cat` of each is the same read in the shell's spelling, and meets the same answer.
    @Test(arguments: unusualFileNames)
    func aCatOfAnyNamedFileIsRefusedAndCountedAtBothEnds(file: String, call: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = "cat '\(file)'"
        let expected = call.replacingOccurrences(of: "/x/", with: "")

        let lookup = Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)
        #expect(lookup?.suggestion.call == expected)
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A file no call can name is withheld by the hook and scored out of the share, whether it is read or `cat`ted.
    ///
    /// The scan counted the read as a miss while the hook, with no call to offer, never refused it — so the share was lowered by exactly the reads the tool had declined to claim.
    @Test
    func aFileNoCallCanNameIsWithheldAndScoredOutOfTheShareAtBothEnds() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let path = "/x/Sources/App/Model[1].swift"

        #expect(Self.hookLookup(["tool_name": "Read", "tool_input": ["file_path": path]], noting: recording.log) == nil)
        let read = TranscriptFixture.tally([TranscriptFixture.toolUse("Read", input: ["file_path": path])])
        #expect(read.textSearches == 1)
        #expect(read.total == 0)

        let command = "cat '\(path)'"
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        let cat = TranscriptFixture.tally([Self.bash(command)])
        #expect(cat.textSearches == 1)
        #expect(cat.total == 0)
    }
}

/// The same suite, continued: a lookup whose file has shell punctuation written against it — a subshell's `)`, a substitution's `)` or backtick, a separator with no space before it.
extension AdviceAgreementTests {
    /// A window into one file in each of those spellings.
    static let gluedWindows = [
        "(cd Kit && sed -n '1,30p' Sources/App/Depot.swift)",
        "(head -30 Sources/App/Depot.swift)",
        "(tail -n 20 Sources/App/Depot.swift)",
        #"echo "$(sed -n '1,30p' Sources/App/Depot.swift)""#,
        "lines=$(head -n 30 Sources/App/Depot.swift)",
        "echo `sed -n '1,30p' Sources/App/Depot.swift`",
        "echo $(cd Kit; sed -n '1,30p' Sources/App/Depot.swift;)",
        "echo $(cd Kit&&sed -n '1,30p' Sources/App/Depot.swift||true)",
        "sed -n '1,30p' Sources/App/Depot.swift;echo done",
        "sed -n '1,30p' Sources/App/Depot.swift&&echo done",
    ]

    /// Each is the window it stands for at both ends: the hook judges it as a window into that file, which nothing in this context has located, and the tally counts it in the share as a window into that file.
    ///
    /// With the punctuation read as part of the file name, the window named no Swift file, and every one of these was scored a text search — out of the share, which raised it by exactly the windows written this way.
    @Test(arguments: gluedWindows)
    func aWindowWithPunctuationAgainstItsFileIsARangedReadAtBothEnds(command: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(ShellInspection.windowedReadPath(command, in: nil) == "Sources/App/Depot.swift")
        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "digest Depot")
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A whole read or a search of a file closing a subshell or a substitution is refused with the call that serves that file, and counted as the miss it is.
    ///
    /// Read as part of the word, the `)` left the file unnamed: a `cat` was offered a bare `search` and withheld, and a grep for a name was offered `where` as though it swept a tree.
    @Test(arguments: [
        ("(cat Sources/App/Depot.swift)", "digest Depot"),
        ("(cd Kit && grep -n foo Sources/App/Depot.swift)", "digest Depot.foo"),
        (#"echo "$(grep -n foo Sources/App/Depot.swift)""#, "digest Depot.foo"),
        ("echo `grep -n foo Sources/App/Depot.swift`", "digest Depot.foo"),
    ])
    func aReadOfAFileClosingASubshellIsRefusedAndCountedAtBothEnds(command: String, call: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == call)
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A grep of a file closing a subshell for a pattern naming nothing is refused with that file's digest, and scored as the audit scores any grep of one file for such a pattern — a text search of that file, never the tree form's, which is what the `)` read as part of the word made it.
    @Test
    func aNamesNothingGrepOfAFileClosingASubshellIsThatFilesTextSearch() throws {
        let command = #"(grep -n '1\.0' Sources/App/Depot.swift)"#
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "digest Depot")
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally([Self.bash(command)])
        #expect(tally.textSearchCauses.patternInOneFile == 1)
        #expect(tally.textSearchCauses.patternNamesNothing == 0)
    }

    /// A substitution that does not run — single-quoted, or behind a backslash — is text a printer prints, so it is no lookup at either end: the hook has nothing to refuse and the share nothing to count.
    @Test(arguments: [
        "echo grep '$(grep -n foo Sources/App/Depot.swift)'",
        #"echo grep "\$(grep -n foo Sources/App/Depot.swift)""#,
        "echo cat '`cat Sources/App/Depot.swift`'",
    ])
    func aSubstitutionThatDoesNotRunIsNoLookupAtBothEnds(command: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(recording.rules.isEmpty)
        #expect(TranscriptFixture.tally([Self.bash(command)]).total == 0)
    }

    /// A window inside a substitution does not displace the lookup the command around it makes: the sweep is refused with the call that answers it, and counted as the miss it is even after the window's file was read.
    ///
    /// Taken first because a body runs first, the window named the command — so the hook let the sweep through as the second half of a loop, and the tally scored it a re-read of the open file, out of the share.
    @Test
    func aWindowInsideASubstitutionDoesNotDisplaceItsHostsSweep() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = #"grep -rn Configuration --include='*.swift' Sources --exclude="$(head -1 /repo/Sources/App/Depot.swift)""#

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where Configuration")
        #expect(recording.rules.isEmpty)

        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Depot.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )
        #expect(lookups.last == .cold(file: nil, missed: .resolve))
        // A body is still the lookup where the command around it reads no Swift.
        #expect(ShellInspection.windowedReadPath(#"echo "$(head -1 /repo/Sources/App/Depot.swift)""#, in: nil) == "/repo/Sources/App/Depot.swift")
    }

    /// The same rule at every depth: inside a substitution, the body's own sweep still comes ahead of the window nested in it, however deep the pair sits.
    ///
    /// Read with each body's nested substitutions ahead of its own statements, the window named the command once the sweep was itself inside a substitution — so the hook had nothing to refuse, and the tally scored a re-read of the open file, out of the share.
    @Test(arguments: [
        #"echo "$(grep -rn Configuration --include='*.swift' Sources --exclude="$(head -1 /repo/Sources/App/Depot.swift)")""#,
        #"echo "$(echo "$(grep -rn Configuration --include='*.swift' Sources --exclude="$(head -1 /repo/Sources/App/Depot.swift)")")""#,
    ])
    func aWindowNestedInASubstitutionDoesNotDisplaceItsBodysSweep(command: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log)?.suggestion.call == "where Configuration")
        #expect(recording.rules.isEmpty)

        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Depot.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )
        #expect(lookups.last == .cold(file: nil, missed: .resolve))
    }
}

/// The same suite, continued: a search for a name outside ASCII.
extension AdviceAgreementTests {
    /// A sweep for a name in any script, and for a dotted path of them, is refused with `where` for that name on both surfaces, and counted as the miss it is.
    ///
    /// Read as ASCII, `Café` was `Caf`, a name nobody declared, so the refusal was withheld and the tally scored the sweep a text search; `Überblick.größe` read as a phrase of fragments and was offered nothing. Both left the share. A capitalised type's member path reads as that path, bare dot or escaped, so the dotted one is offered whole.
    @Test(arguments: [("Café", "where Café"), ("Überblick.größe", "where Überblick.größe")])
    func aSweepForAUnicodeNameIsRefusedAndCountedAtBothEnds(pattern: String, call: String) throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let declared: (String) -> Bool = { ["Café", "Überblick", "Überblick.größe"].contains($0) }
        let command = "grep -rn \(pattern) Sources --include=*.swift"
        let input: [String: Any] = ["output_mode": "content", "pattern": pattern, "glob": "*.swift"]

        let refusals = [
            Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log, couldAnswer: declared),
            Self.hookLookup(["tool_name": "Grep", "tool_input": input], noting: recording.log, couldAnswer: declared),
        ]
        #expect(refusals.map { $0?.suggestion.call } == [call, call])
        #expect(recording.rules.isEmpty)

        let tally = TranscriptFixture.tally(
            [Self.bash(command), TranscriptFixture.toolUse("Grep", id: "g1", input: input)],
            couldAnswer: { name, _ in declared(name) }
        )
        #expect(tally.cold == 2)
        #expect(tally.textSearches == 0)
    }

    /// With no filter naming Swift, a sweep of a tree holding it is a lookup only when its pattern is a name — and a Unicode name is one, where an emoji is not.
    ///
    /// Read as ASCII, `grep -rn Überblick Sources` named no symbol and was no lookup at either end, which took a search for a declared name out of the share.
    @Test
    func anUnfilteredSweepIsALookupForAUnicodeNameAndNotForAnEmoji() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let root = try TemporaryDirectory.make("unicode-sweep").appendingPathComponent("unicode-sweep")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("//\n".utf8).write(to: root.appendingPathComponent("Sources/View.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup: (String, [String: Any]) -> PreToolUseCommand.Lookup? = { tool, input in
            Self.treeLookup(tool: tool, input: input, in: root, noting: recording.log)
        }
        let tally: (String, [String: Any]) -> TranscriptTally = { tool, input in
            TranscriptFixture.tally([TranscriptFixture.toolUse(tool, input: input, cwd: root.path)])
        }

        for (tool, input) in [("Bash", ["command": "grep -rn Überblick Sources"]), ("Grep", ["output_mode": "content", "pattern": "Überblick", "path": "Sources"])] {
            #expect(lookup(tool, input)?.suggestion.call == "where Überblick", "\(input)")
            #expect(tally(tool, input).cold == 1, "\(input)")
        }
        for (tool, input) in [("Bash", ["command": "grep -rn 🦊 Sources"]), ("Grep", ["output_mode": "content", "pattern": "🦊", "path": "Sources"])] {
            #expect(lookup(tool, input) == nil, "\(input)")
            #expect(tally(tool, input).total == 0, "\(input)")
            #expect(tally(tool, input).textSearches == 0, "\(input)")
        }

        #expect(recording.rules.isEmpty)
    }

    /// An emoji is no name, so a sweep filtered to Swift for one names nothing: withheld by the hook and scored out of the share, on both surfaces.
    @Test
    func aSweepForAnEmojiIsATextSearchAtBothEnds() throws {
        let recording = try Recording()
        defer { recording.cleanup() }
        let command = "grep -rn 🦊 Sources --include=*.swift"
        let input: [String: Any] = ["output_mode": "content", "pattern": "🦊", "glob": "*.swift"]

        #expect(Self.hookLookup(["tool_name": "Bash", "tool_input": ["command": command]], noting: recording.log) == nil)
        #expect(Self.hookLookup(["tool_name": "Grep", "tool_input": input], noting: recording.log) == nil)
        #expect(recording.rules == ["textSearch", "textSearch"])

        let tally = TranscriptFixture.tally([Self.bash(command), TranscriptFixture.toolUse("Grep", id: "g1", input: input)])
        #expect(tally.textSearches == 2)
        #expect(tally.total == 0)
    }
}

extension AdviceAgreementTests {
    /// One sweep pattern in both spellings — the shell's and the `Grep` tool's regex — and the call that answers it, or `nil` where none does.
    struct Sweep: Sendable, CustomTestStringConvertible {
        let shell: String
        let grep: String
        let call: String?

        init(_ shell: String, _ grep: String, _ call: String?) {
            self.shell = shell
            self.grep = grep
            self.call = call
        }

        var testDescription: String {
            shell
        }
    }

    /// A temporary suppression log and a reader for what landed in it.
    ///
    /// The rules are read back rather than assumed, because a gate whose fire rate is unrecorded is the blindness `SuppressionLog` exists to prevent — and a new gate that quietly logs nothing is exactly how that comes back.
    struct Recording {
        let log: SuppressionLog
        private let fileURL: URL

        init() throws {
            let root = try TemporaryDirectory.make("suppressions")
            fileURL = root.appendingPathComponent("suppressions.jsonl")
            log = SuppressionLog(fileURL: fileURL)
        }

        /// The `rule` field of every line written, in order.
        var rules: [String] {
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }
                return entry["rule"] as? String
            }
        }

        /// The `call` field of every line written, in order, `nil` where a line names no call.
        var calls: [String?] {
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map { line in
                let entry = line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return entry?["call"] as? String
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
    }
}

extension AdviceAgreementTests {
    /// The hook's classification of one call against a fixture repository, with both judgements it would otherwise read off that repository stated.
    ///
    /// The fixture is a plain directory nobody has put a `.git` in, so it stands outside every repository — the case rule 2 already withholds nothing for, whatever it names (``SiftMCP/RepositoryIndex``). What these tests pin is the classification, so that judgement is stated rather than read off the fixture. Out here rather than in the suite because the body above is at its length limit.
    static func treeLookup(tool: String, input: [String: Any], in root: URL, noting log: SuppressionLog) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": tool, "tool_input": input],
            in: root.path,
            noting: log,
            couldAnswer: { _, _ in true }
        )
    }
}
