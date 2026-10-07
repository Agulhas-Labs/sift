//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the transcript audit: the report that names which lookups went around the index, and whose whole value is that it does not flatter.
@Suite(.temporaryDirectories)
struct TranscriptAuditTests {
    private static func toolUse(_ name: String, id: String = "t1", input: [String: Any] = [:], cwd: String? = nil) -> String {
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        object["cwd"] = cwd
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func toolResult(id: String, text: String, isError: Bool = false) -> String {
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]
        if isError {
            result["is_error"] = true
        }
        let object: [String: Any] = ["type": "user", "message": ["content": [result]]]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Builds a `projects/<project>/<session>.jsonl` tree, optionally with subagent transcripts beside it.
    private static func projects(
        session: [String],
        subagents: [[String]] = [],
        project: String = "-Users-someone-Developer-App"
    ) throws -> URL {
        let root = try TemporaryDirectory.make("audit").appendingPathComponent("audit")
        let directory = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("11112222-3333.jsonl")
        try (session.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        if !subagents.isEmpty {
            let agents = directory.appendingPathComponent("11112222-3333").appendingPathComponent("subagents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            for (index, lines) in subagents.enumerated() {
                try (lines.joined(separator: "\n") + "\n")
                    .write(to: agents.appendingPathComponent("agent-\(index).jsonl"), atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    /// The point of the report: the misses are named, not just counted, so there is something to act on.
    @Test
    func coldLookupsAreNamedFileByFile() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Read", id: "b", input: ["file_path": "/repo/DepotCatalog.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("BayGeometry.swift"))
        #expect(report.contains("DepotCatalog.swift"))
        #expect(report.contains("cold"))
    }

    /// The audit prints the same share the status line does, floor and all.
    ///
    /// Three faces render this one number, and if each formatted it itself the machine could say `<1%` on the status line while the audit of the same transcripts said 0% — and 0% here reads as a week in which the index was never used, which is a different and stronger claim than "barely used".
    @Test
    func aNonzeroShareNeverPrintsAsZero() throws {
        var lines = [Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "SummaryState"])]
        for index in 0 ..< 200 {
            lines.append(Self.toolUse("Read", id: "r\(index)", input: ["file_path": "/repo/File\(index).swift"]))
        }
        let root = try Self.projects(session: lines)

        let report = TranscriptAudit.render(projectsDirectory: root)

        // One of 201 rounds to 0, and 0 is the one thing this share is not.
        #expect(report.contains("<1% of the lookups that had a choice"))
        #expect(!report.contains("0% of the lookups"))
    }

    /// A read the index sent you to is reported apart from the misses, and is not one of them.
    @Test
    func guidedReadsAreReportedSeparatelyFromTheMisses() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "SummaryState"]),
            Self.toolResult(id: "a", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nSummaryState — App — SummaryState.swift:2-40"),
            Self.toolUse("Read", id: "b", input: ["file_path": "/repo/SummaryState.swift", "offset": 10, "limit": 5]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("guided"))
        // The one read was guided, so nothing went around the index and the share is whole.
        #expect(report.contains("100%"))
        #expect(!report.contains("SummaryState.swift"))
    }

    /// A search the tool itself declined to claim gets its own row, and is not among the misses it is named apart from.
    ///
    /// The row has to be there whatever the count, like `guided` and `revisited`: a reader comparing this week's audit against last week's needs the line to be missing for a reason, not missing because it happened to be zero.
    @Test
    func textSearchesAreCountedApartFromTheMisses() throws {
        // A count asks how many rather than which, which no index call answers — the half of a
        // withholding this row is for, told apart from the half the index could have served.
        let root = try Self.projects(session: [
            Self.toolUse("Grep", id: "a", input: ["pattern": "SummaryState", "glob": "*.swift", "output_mode": "count"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("text search    1  for text the index does not record"))
        // And it is not one of the misses: nothing went around the index here.
        #expect(report.contains("cold           0"))
        #expect(!report.contains("cold lookups, worst first"))
    }

    /// The row is split by what the index was missing, because the count alone cannot be acted on.
    ///
    /// Three ordinary causes are pooled in it and they argue for three different things — recording more than declarations, indexing another tree, neither — so a reader asking whether the tool should be reading comment bodies has to be able to see that one line on its own. The lines under the row sum to it, and they stay printed at zero for the same reason `guided` and `revisited` do.
    @Test
    func theTextSearchRowIsSplitByWhatTheIndexWasMissing() throws {
        let root = try Self.projects(session: [
            // A count, which no index call answers whatever its pattern names.
            Self.toolUse("Grep", id: "a", input: ["pattern": "SummaryState", "glob": "*.swift", "output_mode": "count"]),
            // A whole read of a file in a tree no index holds, which no call can name.
            Self.toolUse("Read", id: "b", input: ["file_path": "/Users/someone/App/.build/checkouts/Dep/Sources/Dep/Thing.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("text search    2  for text the index does not record"))
        #expect(report.contains("pattern      1  of those, a pattern naming nothing the index records"))
        #expect(report.contains("path         1  of those, a file no index call can name"))
        // Printed at zero like the rows above it: a reader diffing two audits needs the line missing for a
        // reason rather than because the cause happened not to occur.
        #expect(report.contains("name         0  of those, a name no index on this machine declares"))
    }

    /// A lookup the index could have answered, withheld because its answer costs more round trips than the command, is counted and reported apart from one the index never recorded — and the row carries the share a reader would get without it.
    ///
    /// **One counter for both halves lets the share improve by redefinition.** Every rule added to the withheld half lifts the number while the row explaining it keeps its old name and its old wording, and a lookup the index lost on a judgement of worth reads as one it never owed. So the second group is reported on a row of its own, and the row prices the excuse: without it the same lookups are misses, and that is the share this prints beside the count.
    @Test
    func lookupsWithheldOnWorthAreCountedApartFromTextTheIndexNeverRecorded() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "SummaryState"]),
            Self.toolUse("Grep", id: "b", input: ["pattern": "SummaryState", "glob": "*.swift", "output_mode": "count"]),
            Self.toolUse("Grep", id: "c", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            Self.toolResult(id: "c", text: TranscriptFixture.refusal(), isError: true),
            Self.toolUse("Grep", id: "d", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("text search    1  for text the index does not record"))
        #expect(report.contains("not worth      1  not worth the round trips it would have cost to answer these"))
        // The one index call is the whole share while the re-run is excused; counted as the miss it is,
        // the same session served half of its lookups — the number the row has to print beside the count.
        #expect(report.contains("100% of the lookups that had a choice"))
        #expect(report.contains("counted as misses the share is 50%"))
    }

    /// The `not worth` row is split by rule, mirroring the text-search row's own split: the four argue for four different fixes, and pooling them hides which one applies.
    @Test
    func theNotWorthRowIsSplitByRule() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Bash", id: "b1", input: ["command": #"grep -n "matchedLines" -A8 Sources/App/Depot.swift"#]),
            Self.toolUse("Bash", id: "b2", input: ["command": #"grep -n "waitForExit|temporaryLog" Sources/App/Depot.swift"#]),
            Self.toolUse("Bash", id: "b3", input: ["command": "grep -rn InPlaceShape Sources --include=*.swift | sort -u"]),
            Self.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            Self.toolResult(id: "g1", text: TranscriptFixture.refusal(), isError: true),
            Self.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("not worth      4  not worth the round trips it would have cost to answer these"))
        #expect(report.contains("context      1  of those, a grep of one file printing context around a match that is not a declaration"))
        #expect(report.contains("names        1  of those, an alternation confined to the files it names"))
        #expect(report.contains("filtered     1  of those, a read whose output a later stage filters"))
        #expect(report.contains("retried      1  of those, a refusal whose identical re-run the hook then allowed"))
    }

    /// Lookups from a context that held no sift tools get a bucket of their own, worded so a reader knows where the fix is.
    ///
    /// It is a row and not a silence, because a denominator that quietly shrinks is a count under-reported (Docs/AnswerContract.md §6) and the number on its own reads as a fault of the tool. The durable fix is the agent definition that spawned the context — an allowlist like `tools: Read, Grep, Glob, Bash` strips every MCP server — which is outside anything sift can change, so the report says so rather than filing the miss against a habit nobody had.
    @Test
    func lookupsFromAContextWithNoIndexToolsGetTheirOwnBucket() throws {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap { index in
            [
                Self.toolUse("Read", id: "x\(index)", input: ["file_path": "/repo/Refused\(index).swift"]),
                Self.toolResult(id: "x\(index)", text: TranscriptFixture.refusal(call: "digest Refused\(index)"), isError: true),
            ]
        }
        let root = try Self.projects(
            session: [
                Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "DepotStore"]),
                Self.toolUse("Read", id: "b", input: ["file_path": "/repo/Catalogue.swift"]),
            ],
            // Another server failing says nothing about this one.
            subagents: [[Self.serverFailure("docs")] + refusals + [Self.toolUse("Read", id: "c", input: ["file_path": "/repo/BayGeometry.swift"])]]
        )

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unreachable    1  lookups from contexts holding no sift tools — advice that could not land"))
        #expect(report.contains("(a context that took 12+ refusals or undelivered calls and never once reached the index could not"))
        #expect(report.contains("1 from contexts with no server failure recorded, whose tool list has no sift in it"))
        #expect(report.contains("the durable fix is the agent definition that spawned it, not anything here.)"))
        #expect(!report.contains("failed to start or connect"))
        // The parent reached the index and is judged on its own counters: one call, one miss.
        #expect(report.contains("indexed        1  served by sift — 50% of the lookups that had a choice"))
        #expect(report.contains("cold           1  went around the index"))
        // And the toolless context's read is not among the files named as a digest habit that never formed,
        // while the parent's miss still is: that list is work to do, and reading a file differently could
        // not have avoided this one.
        #expect(!report.contains("BayGeometry.swift"))
        #expect(report.contains("Catalogue.swift"))
    }

    /// The lookups the CLI served are reported on a row inside `indexed`, so a share that moved because of them says why.
    ///
    /// Inside rather than beside, like `answered`: the index served these, off the MCP tools rather than through them. Without the row the count is silent — a context under an output style that mandates the Bash tool reaches the index almost entirely this way, and a reader could not tell that from the tool going unused.
    @Test
    func theLookupsTheCLIServedAreReportedInsideTheIndexedRow() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "DepotStore"]),
            Self.toolUse("Bash", id: "b", input: ["command": "sift where DepotStore"]),
            // Reaching the tool without asking it anything about Swift, which is on no row here.
            Self.toolUse("Bash", id: "c", input: ["command": "sift run -- swift build"]),
            Self.toolUse("Read", id: "d", input: ["file_path": "/repo/Catalogue.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("indexed        2  served by sift — 67% of the lookups that had a choice"))
        #expect(report.contains("on the CLI   1  of those, from a Bash `sift digest`/`where`/`search`/`strings`"))
        #expect(report.contains("cold           1  went around the index"))
    }

    /// A call the harness answered itself is reported as undelivered, never among the index's failures.
    ///
    /// The failure section is the one part of this report that is unambiguously a defect of the tool, so a call that never reached the tool has no place in it.
    @Test
    func aCallTheHarnessNeverDeliveredIsNotReportedAsAFailure() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__where", id: "a", input: ["symbol": "SummaryState"]),
            Self.toolResult(id: "a", text: TranscriptScanTests.undeliveredCallErrors[0], isError: true),
            Self.toolUse("Read", id: "b", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unavailable    1  index calls the harness never delivered"))
        #expect(!report.contains("  failed      "))
        #expect(!report.contains("index calls that failed"))
    }

    /// A call the user declined has a line of its own, and is in neither the failures nor the misses.
    @Test
    func aCallTheUserDeclinedIsReportedAsDeclined() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__where", id: "a", input: ["symbol": "SummaryState"]),
            Self.toolResult(id: "a", text: TranscriptScanTests.declinedCallError, isError: true),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains(
            "  declined       1  index calls stopped at the permission check — declined, or not ruled on in time; neither a failure nor a miss"
        ))
        #expect(report.contains("  cold           0  went around the index"))
        #expect(!report.contains("  failed      "))
        #expect(!report.contains("index calls that failed"))
    }

    /// A file from a since-deleted worktree whose digest served its source is below the floor in the audit, just as it was on the status line.
    ///
    /// Judged against the disk at audit time it could not be read, so it was never excused — and it was listed among the whole reads after a digest, for a digest that had in fact handed back the file. The first touches with no digest to go on are still judged against the disk, and the report says how many, and how many of those it could not read.
    @Test
    func aDeletedFileWhoseDigestServedItsSourceIsBelowTheFloor() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "Sources/App/ChuteTap.swift", "root": "/gone/worktree"]),
            Self.toolResult(id: "a", text: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: true, tree: "worktree")),
            Self.toolUse("Read", id: "b", input: ["file_path": "/gone/worktree/Sources/App/ChuteTap.swift"]),
            Self.toolUse("Read", id: "c", input: ["file_path": "/gone/worktree/Sources/App/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("below floor    1"))
        #expect(!report.contains("ChuteTap.swift"))
        // The other read had no digest to go on, and its file is gone: said, not silently scored.
        #expect(report.contains("1 first touch had"))
        #expect(report.contains("1 of those files cannot be read now, so whether they were under it is unknown"))
    }

    /// Where the transcript records the sift server itself failing, that is the cause named — not an agent definition that was fine.
    ///
    /// A context whose server never started or dropped its connection holds none of the tools however its agent is defined, so pointing at the definition sends a reader to fix something that is not broken. Both causes are pinned side by side: each context is explained by its own transcript.
    @Test
    func anUnreachableContextWhoseServerFailedIsExplainedByTheServer() throws {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap { index in
            [
                Self.toolUse("Read", id: "x\(index)", input: ["file_path": "/repo/Refused\(index).swift"]),
                Self.toolResult(id: "x\(index)", text: TranscriptFixture.refusal(call: "digest Refused\(index)"), isError: true),
            ]
        }
        let serverDown = [Self.serverFailure("sift")] + refusals + [
            Self.toolUse("Read", id: "c", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Read", id: "d", input: ["file_path": "/repo/DepotCatalog.swift"]),
        ]
        let toolless = refusals + [Self.toolUse("Read", id: "e", input: ["file_path": "/repo/Catalogue.swift"])]

        let alone = try TranscriptAudit.render(projectsDirectory: Self.projects(session: [], subagents: [serverDown]))
        #expect(alone.contains("2 from contexts where the sift server failed to start or connect in that session: its"))
        #expect(!alone.contains("the durable fix is the agent definition"))

        let both = try TranscriptAudit.render(projectsDirectory: Self.projects(session: [], subagents: [serverDown, toolless]))
        #expect(both.contains("unreachable    3"))
        #expect(both.contains("2 from contexts where the sift server failed to start or connect in that session: its"))
        #expect(both.contains("1 from contexts with no server failure recorded, whose tool list has no sift in it"))
    }

    /// The harness's report that servers failed, as a transcript records it on the context whose tool list changed.
    private static func serverFailure(_ name: String) -> String {
        let object: [String: Any] = [
            "type": "attachment",
            "attachment": ["type": "deferred_tools_delta", "failedMcpServers": [["name": name]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The row is there whatever the count, like `guided` and `revisited`: a reader comparing one week's audit against another needs the line missing for a reason, not missing because it happened to be zero.
    @Test
    func theUnreachableRowIsPrintedEvenWhenNothingWasUnreachable() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unreachable    0  lookups from contexts holding no sift tools"))
        // The sentence behind it costs three lines and buys nothing where there is nothing to explain.
        #expect(!report.contains("the durable fix is the agent definition"))
    }

    /// Subagent transcripts are the reason this exists — a report that skipped them would miss where the heaviest unindexed reading happens.
    @Test
    func subagentTranscriptsAreAudited() throws {
        let root = try Self.projects(
            session: [Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "DepotStore"])],
            subagents: [[
                Self.toolUse("Read", id: "b", input: ["file_path": "/repo/BayGeometry.swift"]),
                Self.toolUse("Read", id: "c", input: ["file_path": "/repo/BayFloor.swift"]),
            ]]
        )

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("subagent"))
        #expect(report.contains("BayGeometry.swift"))
        #expect(report.contains("BayFloor.swift"))
    }

    /// A preview read below everything the digest described gets its own row, and it is not counted as a digest defect.
    ///
    /// The symbol visitor skips `#if DEBUG` `#Preview` blocks on purpose, so a report filing those reads under "no member the digest listed covers those lines" would be charging the digest for lines nothing was ever going to record.
    @Test
    func aPreviewReadIsRenderedAsContentNoDigestRecords() throws {
        let answer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        BayCard — App — Sources/UI/BayCard.swift:9-80
        struct BayCard: View

        members:
          var body: some View  :12-40
        """
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "d", input: ["target": "BayCard"]),
            Self.toolResult(id: "d", text: answer),
            Self.toolUse("Read", id: "r", input: ["file_path": "/repo/Sources/UI/BayCard.swift", "offset": 82, "limit": 12]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("  1  content a digest does not record"))
        #expect(report.contains("  0  no member the digest listed covers those lines"))
    }

    /// The `N×` example lines are the collapsed containers' names, so they belong directly under the collapsed row — rendered beneath the unattributed row they read as examples of the wrong defect.
    @Test
    func collapsedContainerExamplesRenderUnderTheRowTheyCount() throws {
        let answer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        CrateData — App — Sources/Models/CrateData.swift:9-134
        package struct CrateData: Equatable

        members:
          package init(width: Double?)  :33-53
          struct CrateSet: Identifiable, Equatable — 5 members  :58-70
        """
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "d", input: ["target": "CrateData"]),
            Self.toolResult(id: "d", text: answer),
            Self.toolUse("Read", id: "r", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 58, "limit": 13]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("with no names\n      1× struct CrateSet: Identifiable, Equatable"))
    }

    /// A file rediscovered from source in several separate contexts is the actionable pattern — one cold read is ordinary, the same file cold in three places is a digest habit that never formed.
    @Test
    func filesOpenedColdInSeveralContextsAreCalledOut() throws {
        let read = Self.toolUse("Read", id: "a", input: ["file_path": "/repo/FeedState.swift"])
        let root = try Self.projects(session: [read], subagents: [[read], [read]])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("opened cold in more than one context"))
        #expect(report.contains("FeedState.swift"))
    }

    /// The one list meant to be acted on must not invent a rediscovery.
    ///
    /// Basenames repeat across repositories — `Package.swift`, `Container.swift` — and counting those together would report a file as read cold in two contexts when they were two different files each read once.
    @Test
    func sameNamedFilesFromDifferentPathsDoNotMergeIntoOneRepeatedRow() throws {
        let root = try Self.projects(
            session: [Self.toolUse("Read", id: "a", input: ["file_path": "/repoA/Package.swift"])],
            subagents: [[Self.toolUse("Read", id: "b", input: ["file_path": "/repoB/Package.swift"])]]
        )

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(!report.contains("opened cold in more than one context"))
    }

    /// And the genuine case still reports: the same path, cold in two separate contexts.
    @Test
    func theSameFileColdInTwoContextsIsStillReported() throws {
        let read = Self.toolUse("Read", id: "a", input: ["file_path": "/repo/App/Container.swift"])
        let root = try Self.projects(session: [read], subagents: [[read]])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("opened cold in more than one context"))
        #expect(report.contains("Container.swift"))
    }

    /// Sessions that never touched Swift must not appear, the same silence the status line and primer keep.
    @Test
    func aRunWithNoSwiftLookupsSaysSoRatherThanPrintingAnEmptyTable() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Bash", id: "a", input: ["command": "ls"]),
            Self.toolUse("Read", id: "b", input: ["file_path": "/repo/README.md"]),
        ])

        #expect(TranscriptAudit.render(projectsDirectory: root).contains("nothing to audit"))
    }

    /// An empty or missing transcript directory reports as such rather than as a clean bill of health, which is the same "a typo and genuine silence must not render identically" rule `usage --root` follows.
    @Test
    func anEmptyDirectoryIsReportedRatherThanReadingAsNoMisses() throws {
        let missing = try TemporaryDirectory.make("absent").appendingPathComponent("absent")

        #expect(TranscriptAudit.render(projectsDirectory: missing).contains("no session transcripts found"))
    }

    /// Claude Code names project directories after the flattened absolute path, so every label would otherwise begin with the same home prefix — repeated noise on the one part of the report meant to be scanned.
    @Test
    func aLabelDropsTheHomePrefixAndKeepsWhatIdentifiesTheProject() {
        let session = URL(fileURLWithPath: "/x/.claude/projects/-Users-someone-Developer-Depot/abcdef12-3456.jsonl")

        let label = TranscriptAudit.label(for: session, home: "/Users/someone")

        #expect(label == "Developer-Depot · abcdef12")
    }

    /// A project outside the home directory is left as found rather than mangled by a prefix that never matched.
    @Test
    func aProjectOutsideTheHomeDirectoryKeepsItsName() {
        let session = URL(fileURLWithPath: "/x/.claude/projects/-opt-work-Service/abcdef12-3456.jsonl")

        #expect(TranscriptAudit.label(for: session, home: "/Users/someone") == "opt-work-Service · abcdef12")
    }

    /// A window that excludes everything must say so, not report zero misses.
    @Test
    func aWindowThatMatchesNothingIsNotSilentSuccess() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/A.swift"]),
        ])
        let tomorrow = Date().addingTimeInterval(86400)

        #expect(TranscriptAudit.render(projectsDirectory: root, since: tomorrow).contains("no session transcripts found"))
    }

    /// A repo whose modules are mostly guessed is called out — the failure no count in this report can see.
    ///
    /// It is the whole reason the section exists: on a build system whose manifests the resolver cannot read, every answer arrives on time and names a module that does not exist.
    @Test
    func aRootWhoseModulesAreMostlyGuessedIsReported() {
        let lines = AuditModuleHealth.moduleHealth([
            (root: "/work/monorepo", snapshot: ReadOnlyIndex.Snapshot(files: 4000, guessedModules: 3900)),
        ]).joined(separator: "\n")

        #expect(lines.contains("monorepo"))
        #expect(lines.contains("97%"))
        #expect(lines.contains("sift init"))
    }

    /// The handful of loose files every repo has must not fire it, or the signal is buried the day it ships.
    @Test
    func aFewLooseFilesOutsideAManifestAreNotWorthReporting() {
        // Loose-file counts of the size ordinary roots carry: a handful of guessed files in each.
        let lines = AuditModuleHealth.moduleHealth([
            (root: "/repo/app", snapshot: ReadOnlyIndex.Snapshot(files: 646, guessedModules: 4)),
            (root: "/repo/Lantern", snapshot: ReadOnlyIndex.Snapshot(files: 88, guessedModules: 3)),
            (root: "/repo/Tools", snapshot: ReadOnlyIndex.Snapshot(files: 19, guessedModules: 1)),
        ])

        #expect(lines.isEmpty)
    }

    /// A tiny root cannot reach the threshold on one file, and a report naming it would be noise dressed as a finding.
    @Test
    func aRootTooSmallToJudgeIsLeftAlone() {
        #expect(AuditModuleHealth.moduleHealth([
            (root: "/repo/Scratch", snapshot: ReadOnlyIndex.Snapshot(files: 4, guessedModules: 4)),
        ]).isEmpty)
    }

    /// Several roots on one machine can be called `app`, so a bare directory name merges them into one line about the wrong repository.
    @Test
    func rootsSharingADirectoryNameAreDistinguishedByTheirParent() {
        let lines = AuditModuleHealth.moduleHealth([
            (root: "/Developer/Orchard/app", snapshot: ReadOnlyIndex.Snapshot(files: 100, guessedModules: 90)),
            (root: "/Developer/Depot/app", snapshot: ReadOnlyIndex.Snapshot(files: 100, guessedModules: 80)),
            (root: "/Developer/Lantern", snapshot: ReadOnlyIndex.Snapshot(files: 100, guessedModules: 70)),
        ]).joined(separator: "\n")

        #expect(lines.contains("Orchard/app"))
        #expect(lines.contains("Depot/app"))
        // The unambiguous one stays short — the qualifier is there to disambiguate, not as decoration.
        #expect(lines.contains(" Lantern "))
    }
}

// MARK: - Root scope

extension TranscriptAuditTests {
    /// A transcript's `cwd` decides whether it counts toward a root's tallies, exactly as a logged call's `root` field decides for `usage` — canonically compared, so a nested directory still matches and an unrelated one does not.
    @Test
    func talliesAreScopedByATranscriptsCwd() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/Wanted.swift"], cwd: "/work/Wanted/app"),
        ])

        #expect(TranscriptAudit.tallies(projectsDirectory: root, root: "/work/Wanted").totals.total == 1)
        #expect(TranscriptAudit.tallies(projectsDirectory: root, root: "/work/Elsewhere").totals.total == 0)
    }

    /// This one stands up a real directory so the canonical comparison is actually exercised, unlike every scoping test above, whose `cwd` does not exist on disk and so falls back to `CanonicalPath.of` returning the literal string.
    ///
    /// The recorded `cwd` differs from the root only in case, which a plain string check would read as outside it. `root` is passed canonical, as `LogScope` hands it in production — the comparison this pins is over `recordedCwd`, not over `root` itself.
    @Test
    func aDifferentlyCasedCwdWithinARealRootStillScopes() throws {
        let base = try TemporaryDirectory.make("audit-canon").appendingPathComponent("audit-canon")
        let rootDir = base.appendingPathComponent("Depot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try #require(
            FileManager.default.fileExists(atPath: rootDir.path.uppercased())
                && FileManager.default.fileExists(atPath: rootDir.path.lowercased()),
            "case-sensitive volume — nothing to fold"
        )
        let shouted = rootDir.deletingLastPathComponent().appendingPathComponent(rootDir.lastPathComponent.uppercased()).path

        let session = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/Wanted.swift"], cwd: shouted),
        ])

        let tallies = TranscriptAudit.tallies(projectsDirectory: session, root: CanonicalPath.of(rootDir.path))

        #expect(tallies.totals.total == 1)
    }

    /// A symlinked project directory is followed rather than skipped: `contentsOfDirectory` throws for a directory reached through a symlink, and an unreadable directory reads exactly like a project with no sessions unless the symlink is resolved.
    @Test
    func aSymlinkedProjectDirectoryIsNotSkipped() throws {
        let base = try TemporaryDirectory.make("audit").appendingPathComponent("audit")
        let real = base.appendingPathComponent("real-project", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try (Self.toolUse("Read", input: ["file_path": "/repo/Wanted.swift"]) + "\n")
            .write(to: real.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)

        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: projects.appendingPathComponent("-Users-someone-Developer-App"),
            withDestinationURL: real
        )

        let tallies = TranscriptAudit.tallies(projectsDirectory: projects)

        #expect(tallies.transcripts == 1)
        #expect(tallies.totals.cold == 1)
    }

    /// A subagent is scoped by its own `cwd`, not its parent's: an agent dispatched into the root from a session started outside it counts toward the root, and the parent still does not.
    @Test
    func aSubagentInsideTheRootCountsWhenItsParentIsOutside() throws {
        let root = try Self.projects(
            session: [Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"], cwd: "/work/Elsewhere")],
            subagents: [[Self.toolUse("Read", id: "b", input: ["file_path": "/repo/Wanted.swift"], cwd: "/work/Wanted/app")]]
        )

        let tallies = TranscriptAudit.tallies(projectsDirectory: root, root: "/work/Wanted")

        #expect(tallies.totals.total == 1)
        #expect(tallies.sessions == 1)
    }

    /// `render`'s own `--root` scoping, the shape `sift audit --root` resolves down to: a call whose transcript's `cwd` sits in another repository is left out of the rendered audit entirely, not merely uncounted in a tally.
    @Test
    func renderLeavesOutACallFromAnotherRoot() throws {
        let root = try Self.projects(
            session: [Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"], cwd: "/work/Elsewhere")],
            subagents: [[Self.toolUse("Read", id: "b", input: ["file_path": "/repo/Wanted.swift"], cwd: "/work/Wanted/app")]]
        )

        let scoped = TranscriptAudit.render(projectsDirectory: root, root: "/work/Wanted")
        let unscoped = TranscriptAudit.render(projectsDirectory: root)

        #expect(scoped.contains("Wanted.swift"))
        #expect(!scoped.contains("BayGeometry.swift"))
        #expect(unscoped.contains("BayGeometry.swift"))
    }

    /// A symlinked transcript is dated by the file it points at, not by the link: the link's own date is when it was made, and a window judged on it drops a transcript that is still being written.
    @Test
    func aSymlinkedTranscriptIsDatedByItsTarget() throws {
        let base = try TemporaryDirectory.make("audit").appendingPathComponent("audit")
        let real = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appendingPathComponent("11112222-3333.jsonl")
        try (Self.toolUse("Read", input: ["file_path": "/repo/Wanted.swift"]) + "\n").write(to: target, atomically: true, encoding: .utf8)

        let project = base.appendingPathComponent("projects").appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = project.appendingPathComponent("11112222-3333.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // The link itself dated long before the window; the target, just written, sits inside it.
        var times = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_000_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, link.path, &times, AT_SYMLINK_NOFOLLOW) == 0)

        let tallies = TranscriptAudit.tallies(projectsDirectory: base.appendingPathComponent("projects"), since: Date() - 86400)

        #expect(tallies.transcripts == 1)
        #expect(tallies.totals.cold == 1)
    }

    /// A symlink beside the real project directory it points at reaches the same transcripts under a second name; each one must still be counted once, not once per name that reached it.
    @Test
    func aSymlinkedProjectDuplicatingASiblingDoesNotDoubleCountItsSessions() throws {
        let base = try TemporaryDirectory.make("audit").appendingPathComponent("audit")
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let real = projects.appendingPathComponent("-Users-someone-Developer-App", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try (Self.toolUse("Read", input: ["file_path": "/repo/Wanted.swift"]) + "\n")
            .write(to: real.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)

        try FileManager.default.createSymbolicLink(
            at: projects.appendingPathComponent("-Users-someone-worktrees-App"),
            withDestinationURL: real
        )

        let tallies = TranscriptAudit.tallies(projectsDirectory: projects)

        #expect(tallies.transcripts == 1)
        #expect(tallies.totals.cold == 1)
    }

    /// A `cwd` line far longer than the old fixed-byte probe was still scoped: the probe now reads by line, with no byte cap on any one line.
    @Test
    func aFirstCwdLineNearAHundredKilobytesIsStillScoped() throws {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "a", "name": "Read", "input": ["file_path": "/repo/Wanted.swift"]]]],
            "cwd": "/work/Wanted/app",
            "padding": String(repeating: "x", count: 100_000),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let line = try #require(String(bytes: data, encoding: .utf8))

        let root = try Self.projects(session: [line])

        let tallies = TranscriptAudit.tallies(projectsDirectory: root, root: "/work/Wanted")

        #expect(tallies.totals.total == 1)
    }
}

extension TranscriptAuditTests {
    /// The `not worth` row is there whatever the count, like `guided` and `revisited`: a reader comparing one week's audit against another needs the line missing for a reason, not missing because it happened to be zero — and at zero the trailing share clause drops rather than restating the headline.
    @Test
    func theNotWorthRowIsPrintedEvenWhenNothingWasWithheldOnWorth() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("not worth      0  not worth the round trips it would have cost to answer these"))
        #expect(!report.contains("counted as misses the share is"))
    }

    /// A grep of one file for a literal is a text search, out of the share as the tree form of the same grep is, and the share line states the old denominator beside the new one so the accounting change is read off the report.
    @Test
    func aOneFileLiteralGrepIsATextSearchAndTheOldShareIsPrintedBesideTheNew() throws {
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", input: ["target": "SummaryState"]),
            Self.toolUse("Read", id: "b", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Bash", id: "c", input: ["command": "grep -n \"#127\" Sources/App/View.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("indexed        1  served by sift — 50% of the lookups that had a choice — on the old denominator 33% (text searches in one file +1)"), "\(report)")
        #expect(report.contains("cold           1  went around the index"), "\(report)")
        #expect(report.contains("one file     1  of those, a grep of one file for a pattern naming nothing a declaration could be"), "\(report)")
    }
}
