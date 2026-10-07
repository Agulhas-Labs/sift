//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The refusals section beyond the round trip itself: the price split and its input-equivalent, what followed each lone refusal, where it happened, and the day it landed on.
@Suite(.temporaryDirectories)
struct RefusalCostAndContextTests {
    private static var grep: String {
        "grep -n 'func go' /repo/Sources/App/Alpha.swift"
    }

    private static var refusal: String {
        TranscriptFixture.refusal(call: "digest Alpha.go")
    }

    private static func refused(id: String, turn: String, command: String = grep) -> [Data] {
        [
            TranscriptTurns.call("Bash", id: id, input: ["command": command], turn: turn),
            TranscriptTurns.result(id: id, text: refusal, isError: true),
        ]
    }

    /// `line`, stamped with `timestamp` — `TranscriptTurns` carries none, and the per-day section needs one.
    private static func dated(_ line: Data, at timestamp: String) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return line }
        object["timestamp"] = timestamp
        return (try? JSONSerialization.data(withJSONObject: object)) ?? line
    }

    /// A `prompt_snapshot` attachment declaring `names` as the context's tool list — the harness's own record of what a request could call.
    private static func promptSnapshot(tools names: [String]) -> Data {
        let object: [String: Any] = [
            "type": "attachment",
            "attachment": ["type": "prompt_snapshot", "tools": names.map { ["name": $0] }],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A session transcript, with as many subagent transcripts beside it as `subagents` holds.
    private static func projects(session: [Data], subagents: [[Data]] = []) throws -> URL {
        let root = try TemporaryDirectory.make("refusal-cost").appendingPathComponent("refusal-cost")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(session.flatMap { $0 + [0x0A] }).write(to: directory.appendingPathComponent("11112222-3333.jsonl"))
        if !subagents.isEmpty {
            let agents = directory.appendingPathComponent("11112222-3333/subagents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            for (index, lines) in subagents.enumerated() {
                try Data(lines.flatMap { $0 + [0x0A] }).write(to: agents.appendingPathComponent("agent-\(index).jsonl"))
            }
        }
        return root
    }

    /// The local day the report will print for an ISO-8601 instant, resolved the way the report resolves it.
    private static func localDay(_ instant: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let date = try #require(ISO8601DateFormatter().date(from: instant), sourceLocation: sourceLocation)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: Price split

    /// `message.usage`'s own `cache_creation` split prices a five-minute write and a one-hour write differently — ×1.25 against ×2 — because the harness is explicit about which was which.
    @Test
    func theCacheCreationSplitPricesFiveMinuteAndOneHourWritesDifferently() {
        let next = TranscriptTurns.Usage(input: 3, cacheRead: 1000, cacheCreation5m: 400, cacheCreation1h: 500)
        let lines = Self.refused(id: "c1", turn: "m1") + [TranscriptTurns.text("Next.", turn: "m2", usage: next)]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.resentCost.uncachedInputTokens == 3)
        #expect(tally.resentCost.cacheReadTokens == 1000)
        #expect(tally.resentCost.cacheWrite5mTokens == 400)
        #expect(tally.resentCost.cacheWrite1hTokens == 500)
        // 3×1 + 1000×0.1 + 400×1.25 + 500×2 = 3 + 100 + 500 + 1000
        #expect(tally.resentCost.inputEquivalentTokens == 1603)
    }

    /// A transcript with no `cache_creation` split — the shape every harness wrote before it existed — reads its flat `cache_creation_input_tokens` as entirely five-minute, the cheaper of the two, rather than guess.
    @Test
    func aFlatCacheCreationFigureFallsBackToFiveMinute() {
        let next = TranscriptTurns.Usage(input: 2, cacheRead: 0, cacheCreation: 800)
        let lines = Self.refused(id: "c1", turn: "m1") + [TranscriptTurns.text("Next.", turn: "m2", usage: next)]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.resentCost.cacheWrite5mTokens == 800)
        #expect(tally.resentCost.cacheWrite1hTokens == 0)
    }

    /// A cache read is priced far below uncached input — ×0.1 — which is the whole reason a headline built from the raw total overstates what a round trip costs.
    @Test
    func aCacheReadIsPricedAtATenthOfUncachedInput() {
        let next = TranscriptTurns.Usage(input: 0, cacheRead: 500_000)
        let lines = Self.refused(id: "c1", turn: "m1") + [TranscriptTurns.text("Next.", turn: "m2", usage: next)]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.resentCost.rawTokens == 500_000)
        #expect(tally.resentCost.inputEquivalentTokens == 50000)
    }

    /// The rendered headline leads with the input-equivalent figure and keeps the raw total beside it, split into its three kinds.
    @Test
    func theRenderedHeadlineLeadsWithInputEquivalentAndKeepsTheRawTotal() throws {
        let next = TranscriptTurns.Usage(input: 3, cacheRead: 1000, cacheCreation5m: 400, cacheCreation1h: 500)
        let session = Self.refused(id: "c1", turn: "m1") + [TranscriptTurns.text("Next.", turn: "m2", usage: next)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("1,603 tokens input-equivalent re-sent (1,903 tokens raw: 3 tokens uncached, 1,000 tokens cache reads, 900 tokens cache writes)"))
        #expect(report.contains("uncached ×1, cache read ×0.1, cache write ×1.25 [5-minute] / ×2 [1-hour] — a price comparison against the uncached input rate, not a token count"))
    }

    // MARK: Follow-up classes

    /// A refusal that shared its turn with another call is never priced, so it never enters a follow-up class either — the exclusion is complete, not partial.
    @Test
    func aRefusalNotAloneInItsTurnHasNoFollowUp() {
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": Self.grep], turn: "m1"),
            TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Beta.swift"], turn: "m1"),
            TranscriptTurns.result(id: "c1", text: Self.refusal, isError: true),
            TranscriptTurns.result(id: "e1", text: "The file has been updated."),
            TranscriptTurns.call("mcp__sift__where", id: "w1", input: ["symbol": "Foo"], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000)),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.soloRefusals == 0)
        #expect(tally.reRunFollowUp == RefusalFollowUpTally())
        #expect(tally.indexFollowUp == RefusalFollowUpTally())
        #expect(tally.otherFollowUp == RefusalFollowUpTally())
        #expect(tally.endedFollowUp == RefusalFollowUpTally())
    }

    /// A solo refusal followed by the identical call, re-run, is charged nothing more but is counted as having bought nothing.
    @Test
    func aSoloRefusalFollowedByTheIdenticalCallIsAReRun() {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("Bash", id: "c2", input: ["command": Self.grep], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000))]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.soloRefusals == 1)
        #expect(tally.reRunFollowUp.count == 1)
        #expect(tally.indexFollowUp == RefusalFollowUpTally())
    }

    /// A solo refusal followed by an `mcp__sift__*` tool is counted as redirected to the index.
    @Test
    func aSoloRefusalFollowedByAnIndexToolIsRedirected() {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("mcp__sift__digest", id: "d1", input: ["target": "Alpha"], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000))]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexFollowUp.count == 1)
        #expect(tally.reRunFollowUp == RefusalFollowUpTally())
    }

    /// A solo refusal followed by `sift digest` from Bash is redirected too — the CLI form of the same tool.
    @Test
    func aSoloRefusalFollowedByTheCLIIsRedirected() {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("Bash", id: "d1", input: ["command": "sift digest Alpha"], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000))]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexFollowUp.count == 1)
    }

    /// A solo refusal followed by anything else — neither the same call again nor the index — is `other`.
    @Test
    func aSoloRefusalFollowedByAnUnrelatedCallIsOther() {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Beta.swift"], turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000))]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.otherFollowUp.count == 1)
    }

    /// A solo refusal with no further tool call before the transcript ends is `ended`, not guessed at.
    ///
    /// Decided only once the transcript is known to have ended, exactly as `couldNotReachTheIndex` is decided only once a whole transcript is known — so this goes through the full sweep (`TranscriptAudit.tallies`) rather than `TranscriptFixture.tally`, which folds a line sequence with no "end of transcript" of its own.
    @Test
    func aSoloRefusalWithNothingAfterItIsEnded() throws {
        let lines = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.text("Taking the digest instead.", turn: "m2", usage: TranscriptTurns.Usage(cacheRead: 1000))]
        let root = try Self.projects(session: lines)
        defer { try? FileManager.default.removeItem(at: root) }

        let totals = TranscriptAudit.tallies(projectsDirectory: root).totals

        #expect(totals.endedFollowUp.count == 1)
        #expect(totals.otherFollowUp == RefusalFollowUpTally())
    }

    /// The rendered section prints a count and the input-equivalent tokens for each class, in order: re-run, index, other, ended.
    @Test
    func theRenderedSectionOrdersTheFollowUpClasses() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let session = Self.refused(id: "c1", turn: "m1")
            + [TranscriptTurns.call("Bash", id: "c1b", input: ["command": Self.grep], turn: "m2", usage: usage)]
            + Self.refused(id: "c2", turn: "m3", command: "grep -n 'func stop' /repo/Sources/App/Beta.swift")
            + [TranscriptTurns.call("mcp__sift__digest", id: "d1", input: ["target": "Beta"], turn: "m4", usage: usage)]
            + Self.refused(id: "c3", turn: "m5", command: "grep -n 'func run' /repo/Sources/App/Gamma.swift")
            + [TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Delta.swift"], turn: "m6", usage: usage)]
            + Self.refused(id: "c4", turn: "m7", command: "grep -n 'func end' /repo/Sources/App/Epsilon.swift")
            + [TranscriptTurns.text("Done.", turn: "m8", usage: usage)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)
        let lines = report.split(separator: "\n").map(String.init)
        let reRun = try #require(lines.firstIndex { $0.contains("re-run unchanged") })
        let index = try #require(lines.firstIndex { $0.contains("redirected to the index") })
        let other = try #require(lines.firstIndex { $0.contains("went on to something else") })
        let ended = try #require(lines.firstIndex { $0.contains("nothing after them") })

        #expect(reRun < index)
        #expect(index < other)
        #expect(other < ended)
        #expect(lines[reRun].hasPrefix("  1 re-run unchanged"))
        #expect(lines[index].hasPrefix("  1 redirected to the index"))
        #expect(lines[other].hasPrefix("  1 went on to something else"))
        #expect(lines[ended].hasPrefix("  1 with nothing after them"))
    }

    // MARK: Where

    /// Lone refusals split by where they happened: the main context, a subagent whose `prompt_snapshot` names one of this server's tools, and a subagent whose never does.
    @Test
    func loneRefusalsAreSplitByWhereTheyHappened() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let main = Self.refused(id: "m1", turn: "t1") + [TranscriptTurns.text("Next.", turn: "t2", usage: usage)]
        let subagentWithTools = [Self.promptSnapshot(tools: ["mcp__sift__where", "Bash"])]
            + Self.refused(id: "a1", turn: "s1") + [TranscriptTurns.text("Next.", turn: "s2", usage: usage)]
        let subagentWithoutTools = [Self.promptSnapshot(tools: ["Read", "Bash"])]
            + Self.refused(id: "b1", turn: "u1") + [TranscriptTurns.text("Next.", turn: "u2", usage: usage)]
        let root = try Self.projects(session: main, subagents: [subagentWithTools, subagentWithoutTools])
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("where: 1 in the main context, 1 in a subagent holding sift's tools, 1 in a subagent that never did"))
    }

    /// A subagent whose index tools arrived deferred holds them, though no `prompt_snapshot` it wrote ever names one — a deferred tool is listed only in the `deferred_tools_delta` that added it, which is how this server's tools usually reach a context.
    @Test
    func aSubagentWhoseToolsArrivedDeferredHoldsThem() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let delta: [String: Any] = [
            "type": "attachment",
            "attachment": ["type": "deferred_tools_delta", "addedNames": ["WebFetch", "mcp__sift__digest"], "removedNames": []],
        ]
        let deferred = try [JSONSerialization.data(withJSONObject: delta), Self.promptSnapshot(tools: ["Read", "Bash", "ToolSearch"])]
            + Self.refused(id: "d1", turn: "s1") + [TranscriptTurns.text("Next.", turn: "s2", usage: usage)]
        let root = try Self.projects(session: [], subagents: [deferred])
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("where: 0 in the main context, 1 in a subagent holding sift's tools, 0 in a subagent that never did"))
    }

    /// A subagent whose transcript never records its tool list whole — no `prompt_snapshot`, no `deferred_tools_delta` — has settled neither way whether it held sift's tools, and must not be folded into "never did", which is the harness's own word that the list was checked and came up empty.
    @Test
    func aSubagentWithNoToolListOnRecordIsNamedApart() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let main = Self.refused(id: "m1", turn: "t1") + [TranscriptTurns.text("Next.", turn: "t2", usage: usage)]
        let subagentWithoutTools = [Self.promptSnapshot(tools: ["Read", "Bash"])]
            + Self.refused(id: "b1", turn: "u1") + [TranscriptTurns.text("Next.", turn: "u2", usage: usage)]
        let subagentWithNoToolListOnRecord = Self.refused(id: "c1", turn: "v1") + [TranscriptTurns.text("Next.", turn: "v2", usage: usage)]
        let root = try Self.projects(session: main, subagents: [subagentWithoutTools, subagentWithNoToolListOnRecord])
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains(
            "where: 1 in the main context, 0 in a subagent holding sift's tools, 1 in a subagent that never did, 1 in a subagent with no tool list on record"
        ))
    }

    // MARK: Shapes and redaction

    /// The refused calls a lone re-run followed are listed verbatim, redacted the way a file name is redacted everywhere else in the report unless `--unredact` is asked for.
    @Test
    func theTopReRunCallsAreRedactedUnlessUnredacted() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let command = "grep -n 'func go' /repo/Sources/App/Widget.swift"
        let session = Self.refused(id: "c1", turn: "m1", command: command)
            + [TranscriptTurns.call("Bash", id: "c2", input: ["command": command], turn: "m2", usage: usage)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let unredacted = TranscriptAudit.render(projectsDirectory: root)
        #expect(unredacted.contains("/repo/Sources/App/Widget.swift"))
        #expect(unredacted.contains("grep -n 'func go'"))

        let redactor = Redactor(salt: Data("test-salt".utf8))
        let redacted = TranscriptAudit.render(projectsDirectory: root, redactor: redactor)
        #expect(!redacted.contains("/repo/Sources/App/Widget.swift"))
        // The quoted search phrase is one operand under the allowlist rule, redacted as a whole —
        // unlike the old denylist, which only caught the path and left "'func go'" sitting in the clear.
        #expect(!redacted.contains("func go"))
        #expect(redacted.contains("grep"))
        #expect(redacted.contains("-n"))
        #expect(redacted.contains("re-run shapes:"))
    }

    /// A bare file name and the symbol a search went looking for are hidden even with no `/` in sight — the earlier redaction only caught a path, so `grep -n refusalRoundTrip TranscriptScan.swift` printed both the file and the name in the clear.
    @Test
    func theTopReRunCallsRedactABareFileNameAndItsSearchPattern() throws {
        let command = "cd Sources/SiftMCP && grep -n refusalRoundTrip TranscriptScan.swift"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let session = Self.refused(id: "c1", turn: "m1", command: command)
            + [TranscriptTurns.call("Bash", id: "c2", input: ["command": command], turn: "m2", usage: usage)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let unredacted = TranscriptAudit.render(projectsDirectory: root)
        #expect(unredacted.contains("TranscriptScan.swift"))
        #expect(unredacted.contains("refusalRoundTrip"))
        #expect(unredacted.contains("SiftMCP"))

        let redactor = Redactor(salt: Data("test-salt".utf8))
        let redacted = TranscriptAudit.render(projectsDirectory: root, redactor: redactor)
        #expect(!redacted.contains("TranscriptScan.swift"))
        #expect(!redacted.contains("refusalRoundTrip"))
        #expect(!redacted.contains("SiftMCP"))
    }

    /// `git show`'s `rev:path` keeps its revision in the clear and redacts only the file half.
    ///
    /// Direct against `redactedCall`, rather than through a transcript: `git show` mentions a revision, which the offline scan's own lookup gate does not credit as a read of the working tree (`ShellInspection` — out of this fix's scope), so the shape this pins is exercised the same way `RefusalShapeTests` exercises `refusedCallShape` itself, on the exact text a real refusal would carry.
    @Test
    func redactedCallKeepsTheRevisionAndRedactsOnlyTheFileHalf() {
        let text = TranscriptScan.refusedCallShape(bash: "git show HEAD:Package.swift").text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("Package.swift"))
        #expect(redacted.contains("HEAD:"))
    }

    /// A plain `cat` of a file with no `/` in its name is still a file name.
    @Test
    func redactedCallHidesABareFileNameWithNoSlash() {
        let text = TranscriptScan.refusedCallShape(bash: "cat Package.swift").text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("Package.swift"))
    }

    /// A `Grep`'s `path=`/`glob=` values redact unconditionally, whatever shape they take — `path=Sources` names a directory with neither a `/` nor an extension, and is still the thing being hidden.
    @Test
    func redactedCallHidesGrepPathAndGlobValuesUnconditionally() {
        let text = TranscriptScan.refusedCallShape(
            searchTool: "Grep",
            input: ["pattern": "go", "path": "Sources", "glob": "Foo*.swift"]
        ).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("path=Sources"))
        #expect(!redacted.contains("glob=Foo*.swift"))
        #expect(redacted.contains("pattern="))
    }

    /// A compound pipeline carries more than one pattern, and its words end in `;`, `'` or `)` rather than whitespace — the shape that leaked under the old denylist, which only caught a `/` or a trailing extension.
    ///
    /// The allowlist rule hides everything not explicitly known safe, whatever it is glued to.
    @Test
    func redactedCallHidesEveryNameInACompoundPipeline() {
        let command = """
        grep -n -i warden devkit-hooks.conf; echo ---; \
        grep -n "path\\|url\\|GizmoCore" Tools/GizmoKit/Package.swift; echo ---; \
        grep -rn "isTestFile" Tools | head -5
        """
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        for leaked in ["devkit-hooks", "GizmoCore", "isTestFile", "Tools", "warden", "url"] {
            #expect(!redacted.contains(leaked))
        }

        #expect(redacted.contains("grep"))
        #expect(redacted.contains("-n"))
        #expect(redacted.contains(";"))
        #expect(redacted.contains("|"))
        #expect(redacted.contains("head"))
    }

    /// A multi-line command collapses to one line, in both modes, and a quoted phrase spanning a newline-adjacent word is still hidden as a whole.
    @Test
    func redactedCallCollapsesAMultiLineCommandToOneLine() {
        let command = "grep -n \"blank line\" A.swift\necho \"---\"\ngrep -n \"polishReturnsCount\" B.swift"
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        for leaked in ["polishReturnsCount", "blank", "A.swift"] {
            #expect(!redacted.contains(leaked))
        }

        #expect(!redacted.contains("\n"))
    }

    /// A flag with a value keeps its key and hides its value, and a numeric-looking flag like `-c1-240` is left exactly as written rather than mistaken for an operand.
    @Test
    func redactedCallKeepsFlagsAndTheirKeysButHidesEverythingElse() {
        let command = "grep -rn -i \"nap\" --include='*.swift' Sources Packages | grep -v Tests | grep -i 'stage\\|block' | cut -c1-240 | head -15"
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        for leaked in ["nap", "Sources", "Packages", "stage", "swift'"] {
            #expect(!redacted.contains(leaked))
        }

        #expect(redacted.contains("--include="))
        #expect(redacted.contains("cut -c1-240"))
    }

    /// A `for`/`do` loop with a command substitution: the loop keywords and the file glob's directory are both hidden, one as a bare word and the other as a path.
    @Test
    func redactedCallHidesNamesInsideAForLoopWithCommandSubstitution() {
        let command = "for f in .sift/runs/*.log; do n=$(grep -c \"Test run with\" \"$f\"); done"
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        for leaked in ["Test run", ".sift", "runs"] {
            #expect(!redacted.contains(leaked))
        }
    }

    /// A `Grep` tool display's own `pattern=`/`path=` fields are hidden the same as a shell command's.
    @Test
    func redactedCallHidesGrepToolPatternAndPathFields() {
        let text = TranscriptScan.refusedCallShape(
            searchTool: "Grep",
            input: ["pattern": "checkFirstLaunchStatus", "path": "Sources", "glob": "*.swift"]
        ).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("checkFirstLaunchStatus"))
        #expect(!redacted.contains("Sources"))
    }

    /// A quoted regex excluding a directory by name (`grep -v '/\.build/'`) is hidden as a symbol, not a file — the leak gate caught this: a `\` ahead of the dot reads to `Redactor.file` as a fake basename, and the real word after the dot comes back out as that fake file's plain-text extension.
    @Test
    func redactedCallDoesNotLeakAWordThroughARegexEscapedExclusion() {
        let command = "grep -v '/\\.build/' Sources"
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("build"))
        #expect(!redacted.contains("Sources"))
    }

    /// The same glued-flag leak `aGluedFlagValueNeverLeaksThroughTheShape` pins for `shape(of:)` holds for `redactedCall` too, since both read `looksLikeFlag`.
    @Test(arguments: [
        "git log -SSecretApp --oneline",
        "grep -eSecretRepo Sources",
        "swift build -Xswiftc -DSecretApp",
        "grep -n -- -SecretRepo A.swift",
    ])
    func redactedCallNeverLeaksANameGluedOntoAFlag(command: String) {
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.lowercased().contains("secret"))
    }

    /// `--unredact` (`render` with no redactor) prints every name in the clear, and still collapses a multi-line command to one line — the full pipeline, since a nil redactor never reaches `CallRedaction.redactedCall` at all: `reRunSection` takes the newline-collapsing fallback instead.
    @Test
    func theTopReRunCallsPrintEveryNameUnredactedAndStillCollapseNewlines() throws {
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let command = "grep -n \"blank line\" A.swift\necho \"---\"\ngrep -n \"polishReturnsCount\" B.swift"
        let session = Self.refused(id: "c1", turn: "m1", command: command)
            + [TranscriptTurns.call("Bash", id: "c2", input: ["command": command], turn: "m2", usage: usage)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let unredacted = TranscriptAudit.render(projectsDirectory: root)

        // Collapsed onto one line: the report's own line splitting finds the whole three-command
        // pipeline together, rather than the multi-line command breaking the row across several.
        let reRunLine = try #require(unredacted.split(separator: "\n").first { $0.contains("grep -n") })

        #expect(reRunLine.contains("blank line"))
        #expect(reRunLine.contains("A.swift"))
        #expect(reRunLine.contains("polishReturnsCount"))
        #expect(reRunLine.contains("B.swift"))
    }

    // MARK: Per day

    /// One line per day: how many lone refusals landed on it, and how many of those were a re-run.
    @Test
    func perDaySplitsLoneRefusalsFromReRuns() throws {
        let day1 = "2026-09-12T10:00:00Z"
        let day2 = "2026-09-13T10:00:00Z"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)

        let day1Lines = [
            Self.dated(TranscriptTurns.call("Bash", id: "c1", input: ["command": Self.grep], turn: "m1"), at: day1),
            Self.dated(TranscriptTurns.result(id: "c1", text: Self.refusal, isError: true), at: day1),
            Self.dated(TranscriptTurns.call("Bash", id: "c2", input: ["command": Self.grep], turn: "m2", usage: usage), at: day1),
        ]
        let day2Command = "grep -n 'func stop' /repo/Sources/App/Beta.swift"
        let day2Lines = [
            Self.dated(TranscriptTurns.call("Bash", id: "d1", input: ["command": day2Command], turn: "n1"), at: day2),
            Self.dated(
                TranscriptTurns.result(id: "d1", text: TranscriptFixture.refusal(call: "digest Beta"), isError: true),
                at: day2
            ),
            Self.dated(
                TranscriptTurns.call("Edit", id: "e1", input: ["file_path": "/repo/Sources/App/Gamma.swift"], turn: "n2", usage: usage),
                at: day2
            ),
        ]
        let root = try Self.projects(session: day1Lines + day2Lines)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)
        let localDay1 = try Self.localDay(day1)
        let localDay2 = try Self.localDay(day2)

        #expect(report.contains("\(localDay1)  1 lone refusal, 1 re-run"))
        #expect(report.contains("\(localDay2)  1 lone refusal, 0 re-run"))
    }
}

/// Redirections and newline collapsing, in `CallRedaction` — split from the main body above only to stay under the type-body-length limit.
extension RefusalCostAndContextTests {
    // MARK: Redirections

    /// `--git-dir` (git) and `--type` (rg), added to the value-flag vocabulary beside `-C`, keep the example text's own rule: the flag survives, and no word it was handed does — `git`'s trailing subcommand still reads too, since `--git-dir` takes its value and reopens the verb position right after.
    @Test(arguments: [
        (command: "git --git-dir X log", survives: ["--git-dir", "log"], leaked: ["X"]),
        (command: "rg --type swift Secret F", survives: ["--type", "swift"], leaked: ["Secret", "F"]),
    ])
    func redactedCallKeepsGitDirAndRgTypeFlagsButHidesTheirValues(command: String, survives: [String], leaked: [String]) {
        let text = TranscriptScan.refusedCallShape(bash: command).text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        for word in survives {
            #expect(redacted.contains(word), "\(redacted)")
        }
        for word in leaked {
            #expect(!redacted.contains(word), "\(redacted)")
        }
    }

    /// `2>&1` — the dup form the old code special-cased by its exact text — is still kept whole and verbatim.
    @Test
    func redactedCallKeepsAFileDescriptorDupVerbatim() {
        let text = TranscriptScan.refusedCallShape(bash: "swift test 2>&1 | tail -20").text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(redacted.contains("2>&1"))
    }

    /// Any file descriptor dups the same way, not only `2`, and the close form (`>&-`) too.
    @Test
    func redactedCallKeepsAnyFileDescriptorDupOrCloseVerbatim() {
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let dup = TranscriptAudit.CallRedaction.redactedCall(TranscriptScan.refusedCallShape(bash: "swift test 1>&2").text, by: redactor)
        let close = TranscriptAudit.CallRedaction.redactedCall(TranscriptScan.refusedCallShape(bash: "swift test 3>&-").text, by: redactor)

        #expect(dup.contains("1>&2"))
        #expect(close.contains("3>&-"))
    }

    /// A redirected path is joined to its operator with no space — the earlier split rendered `2 > file-…`, which read as two unrelated words instead of one redirection — and the path itself is still hidden.
    @Test
    func redactedCallJoinsARedirectedPathToItsOperatorAndStillHidesIt() {
        let text = TranscriptScan.refusedCallShape(bash: "swift test 2>secret.log").text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(!redacted.contains("secret"))
        #expect(!redacted.contains("2 >"))
        #expect(redacted.contains("2>file-"))
    }

    /// `/dev/null`, `/dev/stdout` and `/dev/stderr` name nothing about the machine, so a redirection to one renders intact rather than as a pseudonymised file.
    @Test
    func redactedCallKeepsADevNullRedirectionIntact() {
        let text = TranscriptScan.refusedCallShape(bash: "swift test 2>/dev/null").text
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let redacted = TranscriptAudit.CallRedaction.redactedCall(text, by: redactor)

        #expect(redacted.contains("2>/dev/null"))
    }

    /// The append form (`>>`) and the no-descriptor form (`&>`) join and hide their operand the same way as a plain `>`.
    @Test
    func redactedCallJoinsAppendAndNoDescriptorRedirectionsTheSameWay() {
        let redactor = Redactor(salt: Data("test-salt".utf8))

        let appended = TranscriptAudit.CallRedaction.redactedCall(TranscriptScan.refusedCallShape(bash: "swift test 2>>out.log").text, by: redactor)
        let noDescriptor = TranscriptAudit.CallRedaction.redactedCall(TranscriptScan.refusedCallShape(bash: "swift test &>out.log").text, by: redactor)

        #expect(!appended.contains("out.log"))
        #expect(appended.contains("2>>file-"))
        #expect(!noDescriptor.contains("out.log"))
        #expect(noDescriptor.contains("&>file-"))
    }

    // MARK: Newline collapsing

    /// A run of several blank lines between two commands still gives one separator, never one per blank line.
    @Test
    func collapsingNewlinesGivesOneSeparatorForARunOfBlankLines() {
        let text = "grep -n go widget.swift\n\n\n\necho ---"

        let collapsed = TranscriptAudit.CallRedaction.collapsingNewlines(text)

        #expect(collapsed == "grep -n go widget.swift ; echo ---")
    }

    /// A leading or trailing run of newlines is trimmed away entirely rather than becoming a separator.
    @Test
    func collapsingNewlinesTrimsLeadingAndTrailingNewlines() {
        let text = "\n\ngrep -n go widget.swift\n\n"

        let collapsed = TranscriptAudit.CallRedaction.collapsingNewlines(text)

        #expect(collapsed == "grep -n go widget.swift")
    }

    /// A newline inside an open quote is part of the quoted text, not a command boundary — it becomes a single space even though the line before it does not end in a continuation.
    @Test
    func collapsingNewlinesTreatsANewlineInsideAQuoteAsASpace() {
        let text = "echo \"first\nsecond\""

        let collapsed = TranscriptAudit.CallRedaction.collapsingNewlines(text)

        #expect(collapsed == "echo \"first second\"")
    }

    /// A backslash line continuation drops the backslash and joins with a single space rather than ` ; `.
    @Test
    func collapsingNewlinesDropsABackslashContinuationAndJoinsWithASpace() {
        let text = "grep -n go\\\nwidget.swift"

        let collapsed = TranscriptAudit.CallRedaction.collapsingNewlines(text)

        #expect(collapsed == "grep -n go widget.swift")
    }

    /// A multi-line command with a pipe continuation and a `for … do … done` loop reads as one command in the top re-run list, in both modes: the two wrap points (after the pipe, after `do`) collapse to a space, and every other newline — including the one right before `do`, and the one after `done` — collapses to ` ; ` so the loop's body and what follows it still read as separate statements.
    @Test
    func redactedCallSeparatesRealCommandBoundariesFromLineWrapsInBothModes() throws {
        let command = "grep -n go widget.swift |\ngrep -v test\nfor f in *.log\ndo\necho \"$f\"\ndone\necho ---"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let session = Self.refused(id: "c1", turn: "m1", command: command)
            + [TranscriptTurns.call("Bash", id: "c2", input: ["command": command], turn: "m2", usage: usage)]
        let root = try Self.projects(session: session)
        defer { try? FileManager.default.removeItem(at: root) }

        let unredacted = TranscriptAudit.render(projectsDirectory: root)
        #expect(unredacted.contains("| grep -v test"))
        #expect(unredacted.contains("*.log ; do echo"))
        #expect(unredacted.contains("done ; echo ---"))

        let redactor = Redactor(salt: Data("test-salt".utf8))
        let redacted = TranscriptAudit.render(projectsDirectory: root, redactor: redactor)
        #expect(redacted.contains("| grep"))
        #expect(redacted.contains("do echo"))
        #expect(redacted.contains("done ; echo"))
    }
}

/// Re-run examples, one per shape — split from the main body above only to stay under the type-body-length limit.
extension RefusalCostAndContextTests {
    /// Re-run examples list each shape in descending count — `other`, with three re-runs, ahead of `shell window`'s two — with `other` naming the tools its calls came in as (a `Grep` folds in beside the `Bash` calls, since none of `RefusalShape`'s named patterns caught any of them), and the two examples shown per shape are the most recent by day, most recent first, verbatim unless redacted.
    @Test
    func reRunExamplesAreListedPerShapeMostRepeatedFirstWithTheirMostRecentCalls() throws {
        let day1 = "2026-01-01T10:00:00Z"
        let day2 = "2026-01-02T10:00:00Z"
        let day3 = "2026-01-03T10:00:00Z"
        let day4 = "2026-01-04T10:00:00Z"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)

        let otherOldestCommand = "grep -n SummaryState Sources/SiftMCP/Foo.swift"
        let otherNewestCommand = "grep -n RefusalShape Sources/SiftMCP/Bar.swift"
        let grepInput: [String: Any] = ["pattern": "SummaryState", "path": "Sources/SiftMCP/Baz.swift"]
        let sedFoo = "sed -n '1,5p' Sources/SiftMCP/Foo.swift"
        let sedBar = "sed -n '10,20p' Sources/SiftMCP/Bar.swift"

        let lines: [Data] = [
            // other, day1 — not among the top two examples once day2 and day3 outrank it.
            Self.dated(TranscriptTurns.call("Bash", id: "o1", input: ["command": otherOldestCommand], turn: "m1"), at: day1),
            Self.dated(TranscriptTurns.result(id: "o1", text: Self.refusal, isError: true), at: day1),
            Self.dated(TranscriptTurns.call("Bash", id: "o1b", input: ["command": otherOldestCommand], turn: "m1b", usage: usage), at: day1),
            // other, day3 — a Grep, the most recent of the three.
            Self.dated(TranscriptTurns.call("Grep", id: "o2", input: grepInput, turn: "m2"), at: day3),
            Self.dated(TranscriptTurns.result(id: "o2", text: Self.refusal, isError: true), at: day3),
            Self.dated(TranscriptTurns.call("Grep", id: "o2b", input: grepInput, turn: "m2b", usage: usage), at: day3),
            // other, day2 — a Bash call.
            Self.dated(TranscriptTurns.call("Bash", id: "o3", input: ["command": otherNewestCommand], turn: "m3"), at: day2),
            Self.dated(TranscriptTurns.result(id: "o3", text: Self.refusal, isError: true), at: day2),
            Self.dated(TranscriptTurns.call("Bash", id: "o3b", input: ["command": otherNewestCommand], turn: "m3b", usage: usage), at: day2),
            // shell window, day4, twice — the second (Bar.swift) encountered after the first (Foo.swift).
            Self.dated(TranscriptTurns.call("Bash", id: "s1", input: ["command": sedFoo], turn: "m4"), at: day4),
            Self.dated(TranscriptTurns.result(id: "s1", text: Self.refusal, isError: true), at: day4),
            Self.dated(TranscriptTurns.call("Bash", id: "s1b", input: ["command": sedFoo], turn: "m4b", usage: usage), at: day4),
            Self.dated(TranscriptTurns.call("Bash", id: "s2", input: ["command": sedBar], turn: "m5"), at: day4),
            Self.dated(TranscriptTurns.result(id: "s2", text: Self.refusal, isError: true), at: day4),
            Self.dated(TranscriptTurns.call("Bash", id: "s2b", input: ["command": sedBar], turn: "m5b", usage: usage), at: day4),
        ]
        let root = try Self.projects(session: lines)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)
        let reported = report.split(separator: "\n").map(String.init)

        let otherHeader = try #require(reported.firstIndex { $0.contains("other (3)") })
        #expect(reported[otherHeader].contains("by tool: 2 Bash, 1 Grep"))
        // Most recent first: the day3 Grep, then the day2 Bash — the day1 Bash is outranked and not shown.
        #expect(reported[otherHeader + 1].contains("SummaryState"))
        #expect(reported[otherHeader + 2].contains(otherNewestCommand))
        #expect(!reported[otherHeader + 3].contains(otherOldestCommand))

        let shellHeader = try #require(reported.firstIndex { $0.contains("shell window (2):") })
        #expect(shellHeader > otherHeader)
        #expect(reported[shellHeader + 1].contains("Bar.swift"))
        #expect(reported[shellHeader + 2].contains("Foo.swift"))

        // --unredact shows the raw call; the default redacted report hides the file names and search term.
        let redactor = Redactor(salt: Data("test-salt".utf8))
        let redacted = TranscriptAudit.render(projectsDirectory: root, redactor: redactor)
        #expect(!redacted.contains("Bar.swift"))
        #expect(!redacted.contains("Foo.swift"))
        #expect(!redacted.contains("SummaryState"))
    }
}
