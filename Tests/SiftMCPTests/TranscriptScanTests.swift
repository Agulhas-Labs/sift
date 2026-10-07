//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers what counts as a lookup that went *around* the index, which is the whole basis of the adoption number.
struct TranscriptScanTests {
    /// The bug this exists to stop: a digest tells you the line range, you read exactly that range, and the read is scored as evidence that you avoided the index.
    ///
    /// In a session working the loop these can be most of its Swift reads — enough to move the reported share by more than half.
    @Test
    func aReadTheIndexSentYouToIsNotCountedAgainstTheIndex() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("RecordDetailView", id: "d1", file: "Sources/App/RecordDetailView.swift") + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/RecordDetailView.swift")])
    }

    /// A member or nested target locates the file its answer names for the type it belongs to, as the advice hook resolves that type.
    @Test
    func aMemberTargetLocatesTheFileOfItsType() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("RecordDetailState.DetailData", id: "d1", file: "RecordDetailState.swift") + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/RecordDetailState.swift", "offset": 12]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/RecordDetailState.swift")])
    }

    /// A module-qualified target is the other way round — the file is the *last* component — and which one it is cannot be told from the transcript, so both are accepted.
    @Test
    func aModuleQualifiedTargetLocatesItsTypesFile() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["symbol": "SiftCore.DigestRenderer"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/DigestRenderer.swift", "offset": 20]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/DigestRenderer.swift")])
    }

    /// Re-reading a file you are editing is not a lookup the index could have served — the file is already in context.
    ///
    /// An edit sequence re-reads the same file many times, and scoring each one a miss counts the editing as avoidance.
    @Test
    func aRereadOfAFileAlreadyOpenIsNotAMiss() {
        let read = TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/FeedState.swift"])
        let lookups = TranscriptFixture.lookups([read, read, read])

        #expect(lookups == [
            .cold(file: "/repo/FeedState.swift", missed: nil),
            .revisited(file: "/repo/FeedState.swift"),
            .revisited(file: "/repo/FeedState.swift"),
        ])
    }

    /// The counting must not quietly become "full reads only".
    ///
    /// A cold *ranged* read is still a lookup that went around the index — the session knew where to look from somewhere other than the index, and excusing it would make the metric flatter without making it truer.
    @Test
    func aColdRangedReadIsStillAMiss() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/RecordDetailState.swift", "offset": 120, "limit": 30]),
        ])

        #expect(lookups == [.cold(file: "/repo/RecordDetailState.swift", missed: nil)])
    }

    /// Duplicated basenames are ordinary — several `Container.swift`-shaped collisions in one repository is unremarkable — and keying "already read" on the stem scores the second file's *first* read as a re-read of the first, dropping it from the count.
    ///
    /// That flatters the share, which is the one direction it must never round.
    @Test
    func twoFilesSharingABasenameAreCountedSeparately() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/RecordService/Container.swift"]),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/GizmoCore/Container.swift"]),
        ])

        #expect(lookups == [
            .cold(file: "/repo/RecordService/Container.swift", missed: nil),
            .cold(file: "/repo/GizmoCore/Container.swift", missed: nil),
        ])
    }

    /// The same file at the same path is still a re-read — the fix above must not lose that.
    @Test
    func theSamePathIsStillARereadAfterTheBasenameFix() {
        let read = TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/App/Container.swift"])
        let lookups = TranscriptFixture.lookups([read, read])

        #expect(lookups == [.cold(file: "/repo/App/Container.swift", missed: nil), .revisited(file: "/repo/App/Container.swift")])
    }

    /// A whole-file read straight after a digest is the read the digest exists to save, paid anyway, and must not be scored as the loop working.
    @Test
    func aWholeFileReadAfterADigestIsRecordedAsReadWholeAfterItsDigest() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("DepotCatalog", id: "d1", file: "DepotCatalog.swift") + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/DepotCatalog.swift"]),
            ]
        )

        #expect(lookups == [.indexed, .readWholeAfterDigest(file: "/repo/DepotCatalog.swift")])
    }

    /// The advice hook refuses a whole-file read and the session takes the ranged read instead — the loop working, and must not be scored as the digest failing.
    ///
    /// Counting a denied read as read whole after its digest moves the headline against the index every time the deflection works. The read never happened; it cannot be evidence of anything.
    @Test
    func aWholeFileReadTheHookRefusedIsNotADigestFailure() {
        let tally = TranscriptFixture.tally(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "RecordSummaryCard"]) + [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/RecordSummaryCard.swift"]),
                TranscriptFixture.toolResult(id: "r1", isError: true),
            ]
        )

        #expect(tally.readWholeAfterDigest == 0)
        #expect(tally.indexed == 1)
    }

    /// The refused read must not leave the file marked open, or the ranged read that follows it — the whole point of the refusal — is scored a re-read instead of the loop closing.
    @Test
    func theRangedReadAfterARefusedOneIsGuided() {
        let tally = TranscriptFixture.tally(
            TranscriptFixture.answeredDigest("RecordSummaryCard", id: "d1", file: "RecordSummaryCard.swift") + [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/RecordSummaryCard.swift"]),
                TranscriptFixture.toolResult(id: "r1", isError: true),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/RecordSummaryCard.swift", "offset": 1, "limit": 101]),
            ]
        )

        #expect(tally.guided == 1)
        #expect(tally.revisited == 0)
        #expect(tally.readWholeAfterDigest == 0)
    }

    /// A refused read of a file nothing had located is not a miss either — the session never got the file, so it never went around the index.
    @Test
    func aRefusedColdReadIsNotAMiss() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/UsageSnapshot.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: true),
        ])

        #expect(tally.cold == 0)
    }

    /// The retraction must key on the *result*, not on there having been one: a read that succeeded still counts, or the metric quietly becomes zero.
    @Test
    func aReadThatSucceededStillCounts() {
        let tally = TranscriptFixture.tally(
            TranscriptFixture.answeredDigest("StoredEntry", id: "d1", file: "StoredEntry.swift") + [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/StoredEntry.swift"]),
                TranscriptFixture.toolResult(id: "r1", isError: false),
            ]
        )

        #expect(tally.readWholeAfterDigest == 1)
    }

    /// A resolved read's held entry is dropped whether it succeeded or failed — the persisted state this rides in is the status-line's own cache, and an entry never dropped is a leak that outlives every render.
    ///
    /// The success is the half that needs saying: its line carries none of the byte pre-filter's markers — no tool name, no failure flag — so it is parsed at all only because its id is one the scan is holding.
    @Test
    func aResolvedReadDrainsItsPendingEntryWhicheverWayItResolved() {
        var state = TranscriptScanState()
        _ = TranscriptScan.events(line: TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Ok.swift"]), state: &state)
        _ = TranscriptScan.events(line: TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Bad.swift"]), state: &state)
        #expect(state.pendingReads.count == 2)

        _ = TranscriptScan.events(line: TranscriptFixture.toolResult(id: "r1", isError: false), state: &state)
        _ = TranscriptScan.events(line: TranscriptFixture.toolResult(id: "r2", isError: true, text: "boom"), state: &state)

        #expect(state.pendingReads.isEmpty)
    }

    /// The same for an index call: its held entry is dropped once the answer arrives, whether it locates something or comes back an error.
    @Test
    func aResolvedIndexCallDrainsItsPendingEntryWhicheverWayItResolved() {
        var state = TranscriptScanState()
        _ = TranscriptScan.events(line: TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Ok"]), state: &state)
        _ = TranscriptScan.events(line: TranscriptFixture.toolUse("mcp__sift__digest", id: "d2", input: ["target": "Bad"]), state: &state)
        #expect(state.pendingIndexCalls.count == 2)

        _ = TranscriptScan.events(line: TranscriptFixture.indexAnswer(id: "d1", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0"), state: &state)
        _ = TranscriptScan.events(line: TranscriptFixture.toolResult(id: "d2", isError: true, text: "boom"), state: &state)

        #expect(state.pendingIndexCalls.isEmpty)
    }

    /// One turn can issue several reads at once and their results arrive together, so the held reads are keyed by id — a single slot would retract only the last of them and leave the rest counted.
    @Test
    func everyRefusedReadInOneTurnIsRetracted() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/UsageSnapshot.swift"]),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/FlaggedCard.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: true),
            TranscriptFixture.toolResult(id: "r2", isError: true),
        ])

        #expect(tally.cold == 0)
    }

    /// The hook refuses shell lookups on the same rule as reads, and they are ordinarily the larger column.
    ///
    /// Holding only reads would fix the smaller half and leave the share still falling every time the hook succeeded against a grep.
    @Test
    func aShellLookupTheHookRefusedIsNotAMissEither() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -n SummaryState Sources/App/SummaryState.swift", "description": "find it"]),
            TranscriptFixture.toolResult(id: "b1", isError: true),
        ])

        #expect(tally.cold == 0)
    }

    /// A refused Grep is the same case reached through a different tool.
    @Test
    func aRefusedGrepIsNotAMiss() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            TranscriptFixture.toolResult(id: "g1", isError: true),
        ])

        #expect(tally.cold == 0)
    }

    /// A repo-wide name grep that actually ran is still a lookup that went around the index.
    @Test
    func aShellLookupThatRanIsStillAMiss() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -rn --include=*.swift SummaryState Sources", "description": "find it"]),
            TranscriptFixture.toolResult(id: "b1", isError: false),
        ])

        #expect(tally.cold == 1)
    }

    /// An index call's failure and a read's refusal arrive in the same shape, and the failure count is the one thing the status line interrupts anyone about.
    @Test
    func anIndexCallFailureIsStillCountedAlongsideTheReadRetraction() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "InboundCard"]),
            TranscriptFixture.toolResult(id: "w1", isError: true),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/InboundCard.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: true),
        ])

        #expect(tally.failed == 1)
        #expect(tally.cold == 0)
    }

    /// Below the compression floor `digest` serves the source itself, so a session that read the file directly got byte-identical content and avoided nothing.
    @Test
    func aReadOfAFileBelowTheCompressionFloorIsNotAMiss() {
        var state = TranscriptScanState()
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/ChuteTap.swift"]),
            state: &state,
            belowFloor: { _ in true }
        )

        #expect(events == [.lookup(.belowFloor(file: "/repo/ChuteTap.swift"))])
    }

    /// The floor excuses nothing above it: a file big enough for a digest to compress is still a miss.
    @Test
    func aReadOfAFileAboveTheFloorRemainsAMiss() {
        var state = TranscriptScanState()
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/YardView.swift"]),
            state: &state,
            belowFloor: { _ in false }
        )

        #expect(events == [.lookup(.cold(file: "/repo/YardView.swift", missed: nil))])
    }

    /// `where` returns file:line locations and never promised to save you the file, so a whole-file read after one is not a read after any digest.
    ///
    /// Counting it would put "read whole after its digest" against a digest that was never made.
    @Test
    func aWholeFileReadAfterWhereIsNotADigestVerdict() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["symbol": "BaySnapshot"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/BaySnapshot.swift"]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/BaySnapshot.swift", missed: nil)])
    }

    /// `where` still guides a *ranged* read — it located the lines, and the read took them.
    @Test
    func aRangedReadAfterWhereIsStillGuided() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["symbol": "BaySnapshot"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/BaySnapshot.swift", "offset": 20]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/BaySnapshot.swift")])
    }

    /// `Read(file, limit: 40)` is a ranged read with no offset at all, and reading offset alone would file those as whole-file — straight into the count of files read whole after their digest.
    @Test
    func aReadBoundedOnlyByLimitCountsAsRanged() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("SummaryState", id: "d1", file: "SummaryState.swift") + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/SummaryState.swift", "limit": 40]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/SummaryState.swift")])
    }

    /// Below the floor the digest *is* the source, so reading the file whole afterwards got identical bytes and cost nothing the digest saved — the floor has to be tested before the located branch or the majority case lands in the wrong column.
    @Test
    func aWholeFileReadBelowTheFloorIsNotADigestFailure() {
        var state = TranscriptScanState()
        var events: [TranscriptEvent] = []
        for line in [
            TranscriptFixture.toolUse("mcp__sift__digest", input: ["target": "ChuteTap"]),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/ChuteTap.swift"]),
        ] {
            events += TranscriptScan.events(line: line, state: &state, belowFloor: { _ in true })
        }

        #expect(events == [.lookup(.indexed), .lookup(.belowFloor(file: "/repo/ChuteTap.swift"))])
    }

    /// The blind spot this closes: a session can run far more shell inspections than Reads and index calls together, and a metric that saw only the last two would miss most of what went around the index.
    @Test
    func aShellGrepOfSwiftSourceIsALookupThatWentAroundTheIndex() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "grep -n 'func body' Sources/App/View.swift"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: .digest)])
    }

    /// A `sed -n` window into a file a digest just located is the loop working, spelled in shell — scoring it always-cold would make digest-then-window read *worse* than the identical digest-then-ranged-Read.
    ///
    /// Each spelling in a context of its own, because each is a first touch here: a second window into the same context's file is a re-read, pinned below.
    @Test(arguments: ["sed -n '40,60p' Sources/App/RecordDetailView.swift", "head -30 Sources/App/RecordDetailView.swift"])
    func aWindowedShellReadOfAFileAnIndexCallLocatedIsGuided(command: String) {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("RecordDetailView", id: "d1", file: "Sources/App/RecordDetailView.swift") + [
                TranscriptFixture.toolUse("Bash", input: ["command": command]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "Sources/App/RecordDetailView.swift")])
    }

    /// A windowed read nothing located is still a miss — but one that names its file, instead of dissolving into the search bucket.
    @Test
    func aColdWindowedShellReadIsAMissThatNamesItsFile() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "sed -n '1,20p' Sources/App/View.swift"]),
        ])

        #expect(lookups == [.cold(file: "Sources/App/View.swift", missed: nil)])
    }

    /// An unexpanded loop variable is not a nameable file — `sed -n '1,30p' $f.swift` reads real files, but a report row naming `$f.swift` invents one no tree contains.
    ///
    /// It still counts as a lookup that went around the index; it just joins the unnamed search bucket, carrying no call — `ShellAdvice` nudges no windowed read at all, so naming one here would report advice the hook never gave.
    @Test
    func aWindowedReadThroughAShellVariableCountsButNamesNoFile() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "sed -n '1,30p' $f.swift"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: nil)])
    }

    /// A pattern address searches — `sed -n '/init/p'` matches text where a window prints chosen lines — so it stays in the search bucket a locate can never excuse.
    @Test
    func aPatternAddressSedIsASearchNotAWindow() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "View"]) + [
                TranscriptFixture.toolUse("Bash", input: ["command": "sed -n '/init/p' Sources/App/View.swift"]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: nil, missed: .digest)])
    }

    /// Editing and building are ordinary work and must not be counted as misses, or the metric invents them.
    @Test
    func shellWorkThatIsNotALookupContributesNothing() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "sed -i '' 's/a/b/' Sources/App/View.swift"]),
            TranscriptFixture.toolUse("Bash", input: ["command": "swift build 2>&1 | grep error"]),
            TranscriptFixture.toolUse("Bash", input: ["command": "ls -la"]),
        ])

        #expect(lookups.isEmpty)
    }

    /// An index call for one type says nothing about a different file.
    @Test
    func anUnrelatedFileIsStillColdAfterADigest() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "RecordType"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/OrchardApp.swift"]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/OrchardApp.swift", missed: nil)])
    }

    /// A search names no file, so it can never be guided — it stays a miss whatever came before it.
    @Test
    func aSwiftFlavouredSearchIsAlwaysCold() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]) + [
                TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "final class", "glob": "**/*.swift"]),
                TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "TODO", "glob": "**/*.md"]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: nil, missed: .shape)])
    }

    /// The escape hatch every refusal offers by name, scored as the thing the refusal told the caller to do.
    ///
    /// The hook denies the search once and the text of the denial ends by offering this exact command back; `AdviceLedger.decide` then allows the re-run, spending nothing. Counting that re-run cold would make the share fall by exactly the amount the hook succeeded, so the number would go down every time the mechanism worked — the same shape of mistake as a ledger reading a re-run as defiance.
    ///
    /// Withheld on worth rather than as text the index does not record: the hook refused this search because an index call *did* answer it, so the half that says the index never owed the lookup would be a claim the refusal itself contradicts.
    @Test
    func theReRunARefusalOffersIsWithheldOnWorthRatherThanAMiss() {
        let search = TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"])
        let lines = [
            search,
            TranscriptFixture.toolResult(id: "g1", isError: true, text: TranscriptFixture.refusal()),
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ]

        #expect(TranscriptFixture.lookups(lines) == [.cold(file: nil, missed: .resolve), .withheldOnWorth(rule: .retryAllowed)])

        let tally = TranscriptFixture.tally(lines)
        // The denied search was taken back and the re-run never joined the denominator, so the pair
        // leaves the share untouched rather than halving it.
        #expect(tally.withheldOnWorth == 1)
        #expect(tally.textSearches == 0)
        #expect(tally.cold == 0)
        #expect(tally.total == 0)
    }

    /// The same escape hatch at the shell, recognised through the whitespace the model re-types it with.
    ///
    /// The denial arrives here as a **bare string**, which is the shape Claude Code actually writes a hook denial in; the typed content blocks the sibling test uses are the other one. Both reach `answerText`, and a suite building only one of them would pin half the parser.
    @Test
    func aShellSearchIsTheSameSearchHoweverItIsSpaced() {
        let lines = [
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -rn SummaryState Sources/App/SummaryState.swift"]),
            TranscriptFixture.toolResult(id: "b1", isError: true, text: TranscriptFixture.refusal(), bareText: true),
            TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": "grep  -rn   SummaryState \t Sources/App/SummaryState.swift"]),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.withheldOnWorth == 1)
        #expect(tally.cold == 0)
    }

    /// A refusal from anywhere else licenses nothing: the retraction says the search did not happen, not that the next one is sanctioned.
    ///
    /// Every `is_error` result would otherwise open the hatch — a permission prompt declined, a timeout, a bad regex — and the share would rise on the strength of tools failing.
    @Test
    func aSearchDeniedBySomethingElseIsStillAMissWhenItComesBack() {
        let lines = [
            TranscriptFixture.toolUse("Grep", id: "g1", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
            TranscriptFixture.toolResult(id: "g1", isError: true, text: "The user doesn't want to proceed with this tool use."),
            TranscriptFixture.toolUse("Grep", id: "g2", input: ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A search for a name no index on this machine declares is a search for text the index does not record — which is what the hook decided when it stayed silent.
    ///
    /// `PreToolUseCommand.lookup` suppresses advice here because `where SubagentStart` would answer "no symbol named …", and a wrong denial costs more than none. Counting these on the floor principle would make the share fall for asking a question the tool had already declined to claim it could answer.
    @Test
    func aSearchForANameNoIndexDeclaresIsATextSearch() {
        let search = [TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "SubagentStart", "glob": "*.swift"])]

        #expect(TranscriptFixture.lookups(search, couldAnswer: { _, _ in false }) == [.textSearch(cause: .undeclaredName)])
        // And the same search stays a miss where the index does declare the name, which is the ordinary case.
        #expect(TranscriptFixture.lookups(search) == [.cold(file: nil, missed: .resolve)])
    }

    /// The silence only excuses advice that stood on a symbol — a search naming none was never suppressed, so nothing about it was ever the index's own verdict.
    @Test
    func aSearchNamingNoSymbolIsUnaffectedByWhatTheIndexDeclares() {
        let lookups = TranscriptFixture.lookups(
            [TranscriptFixture.toolUse("Glob", input: ["pattern": "**/*.swift"])],
            couldAnswer: { _, _ in false }
        )

        #expect(lookups == [.cold(file: nil, missed: .digest)])
    }

    /// A refused *read* opens no hatch: the file is still there to be digested, and the re-read is the miss it always was.
    ///
    /// The escape hatch exists for text the index does not record, which a whole file is not — so the sanctioned re-run applies to searches and stops there.
    @Test
    func aRefusedReadThatIsRepeatedIsStillAMiss() {
        let lines = [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/SummaryState.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: true, text: TranscriptFixture.refusal(call: "digest SummaryState")),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/SummaryState.swift"]),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.cold == 1)
        #expect(tally.textSearches == 0)
    }

    /// A read through another MCP server is the same read, and counting one without the other would let the refusal displace traffic somewhere the metric cannot see — the share climbing while nothing improved.
    @Test
    func aReadThroughAnotherServerCountsAsTheReadItIs() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("mcp__xcode__XcodeRead", input: ["filePath": "App/Sources/SummaryState.swift"]),
            TranscriptFixture.toolUse("mcp__xcode__XcodeGrep", input: ["output_mode": "content", "pattern": "refresh", "type": "swift"]),
            TranscriptFixture.toolUse("mcp__xcode__XcodeGlob", input: ["pattern": "**/*.swift"]),
            // Not every tool ending in a verb is one of ours: a notebook read carries no file path.
            TranscriptFixture.toolUse("NotebookRead", input: ["notebook_path": "/x/Analysis.ipynb"]),
        ])

        #expect(lookups == [.cold(file: "App/Sources/SummaryState.swift", missed: nil), .cold(file: nil, missed: .resolve), .cold(file: nil, missed: .digest)])
    }

    /// A rule of "swift appears anywhere in the arguments, lowercased" would make a repo *called* Sift score every search it ever ran as a Swift lookup — and a repo called Depot score none.
    @Test
    func aSearchIsJudgedByWhatItSoughtNotByWhatTheRepoIsCalled() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Grep", input: ["output_mode": "content", "pattern": "install", "path": "/repos/Sift/Distribution"]),
            TranscriptFixture.toolUse("Glob", input: ["pattern": "**/*.md", "path": "/repos/Sift"]),
            TranscriptFixture.toolUse("Glob", input: ["pattern": "**/*Store.swift"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: .shape)])
    }

    /// A file digested *after* it was read stays counted — the read happened first and the index did not serve it.
    @Test
    func aDigestAfterTheReadDoesNotRetroactivelyExcuseIt() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/SummaryState.swift"]),
            TranscriptFixture.toolUse("mcp__sift__digest", input: ["target": "SummaryState"]),
        ])

        #expect(lookups == [.cold(file: "/repo/SummaryState.swift", missed: nil), .indexed])
    }

    /// Non-Swift work contributes nothing, which is what keeps the status line silent outside Swift sessions.
    @Test
    func nonSwiftToolUseIsNotALookup() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "ls"]),
            TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/README.md"]),
        ])

        #expect(lookups.isEmpty)
    }
}

// MARK: - A Markdown lookup is outside the population the share is measured over

extension TranscriptScanTests {
    /// Neither side of a document lookup enters the share: not the `digest` that answers it, and not the whole read it stands in for.
    ///
    /// The read population is Swift-only — a whole `Read` of a `.md` is scored as nothing at all — so counting the document's digest would put it in the numerator *and* the denominator with no miss population of its own behind it. Every context that took the Markdown nudge (`ReadAdvice`) would then raise the number the tool is judged on by taking its advice, which is a share that improves by being read from.
    @Test
    func aDocumentDigestAndADocumentReadAreBothOutsideTheShare() {
        let tally = TranscriptFixture.tally(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "Docs/Design.md"]) + [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/README.md"]),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/Depot.swift"]),
            ]
        )

        #expect(tally.indexed == 0)
        #expect(tally.cold == 1)
        #expect(tally.total == 1)
        #expect(tally.share == 0)
    }

    /// A call that named a document *and* Swift source asked the index about Swift, so it counts like any other — the withholding is for a call whose every target is a document.
    @Test
    func aDigestNamingBothADocumentAndSwiftSourceIsALookupLikeAnyOther() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["targets": ["Docs/Design.md", "Depot"]])
        )

        #expect(lookups == [.indexed])
    }

    /// A document digest that failed retracts nothing, because it was never counted: taking one back would report a session whose only call was a failed `.md` digest as minus one lookup.
    @Test
    func aFailedDocumentDigestRetractsNoLookup() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Docs/Design.md"]),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: "no Markdown file at Docs/Design.md"),
        ])

        #expect(tally.indexed == 0)
        #expect(tally.total == 0)
        #expect(tally.failed == 1)
    }

    /// The same ruling on the other face: `sift digest` given a document from the shell is the same lookup by another route, and the route is not what the share asks about.
    @Test
    func aDocumentDigestFromTheShellIsOutsideTheShareToo() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", input: ["command": "sift digest Docs/Design.md"]),
        ])

        #expect(tally.indexed == 0)
        #expect(tally.cliCalls == 1)
        #expect(tally.total == 0)
    }

    /// And a Swift lookup from the shell still counts, so the rule above is about the document rather than about the CLI.
    @Test
    func aSwiftLookupFromTheShellStillCounts() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", input: ["command": "sift digest Depot"]),
        ])

        #expect(tally.indexed == 1)
        #expect(tally.total == 1)
    }
}

// MARK: - Which argument locates a file

extension TranscriptScanTests {
    /// A `path:` argument healed to `target:` server-side is still a bare `path:` key in the *transcript's* own record of the call — the healing happens inside the server, after this scan has already looked at what the model sent — so `locatedNames` has to read the call as the server resolved it, or the ranged read that follows a healed digest scores as a miss.
    @Test
    func aHealedPathArgumentLocatesItsFile() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["path": "Sources/App/RecordDetailView.swift"]),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/RecordDetailView.swift", servedSource: false)),
            ] + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
            ]
        )

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/RecordDetailView.swift")])
    }

    /// Only `digest` has its `path:` healed, so only `digest`'s locates anything: `where` has no argument a `path:` stands for, so a call carrying one was never about that file, and the ranged read after it is as cold as it would have been.
    @Test
    func aPathArgumentToAnotherToolLocatesNothing() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["path": "Sources/App/RecordDetailView.swift"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/Sources/App/RecordDetailView.swift", missed: nil)])
    }

    /// Only the key the tool reads locates a file: `where` resolves its `symbol:`, so a `target:` sent beside it names a file the answer was never about, and the ranged read of that file stays cold while the read of the symbol's own file is guided.
    @Test
    func onlyTheKeyTheToolReadsLocatesAFile() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__where", id: "w1", input: ["symbol": "Widget", "target": "RecordDetailView"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/Sources/App/Widget.swift", "offset": 1, "limit": 20]),
            ]
        )

        #expect(lookups == [
            .indexed,
            .cold(file: "/repo/Sources/App/RecordDetailView.swift", missed: nil),
            .guided(file: "/repo/Sources/App/Widget.swift"),
        ])
    }
}

// MARK: - The digest floor, as the transcript recorded it

extension TranscriptScanTests {
    /// A file whose own digest served its source was below the floor, whatever the disk holds by the time anyone asks.
    ///
    /// The audit runs days later, over worktrees that have since been deleted: judged against the disk, a file that cannot be read is never excused, so the same read scored below the floor on the status line and as a whole read after a digest in the audit. The digest's answer recorded the decision at the time, and it is the one record that outlives the file.
    @Test
    func aFileWhoseDigestServedItsSourceIsBelowTheFloorThoughTheFileIsGone() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/ChuteTap.swift"], cwd: "/gone/worktree"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: true, tree: "worktree")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/gone/worktree/Sources/App/ChuteTap.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .belowFloor(file: "/gone/worktree/Sources/App/ChuteTap.swift")])
    }

    /// The same record decides the other way: a file whose digest summarised it was over the floor, whatever the disk says now.
    @Test
    func aFileWhoseDigestSummarisedItIsOverTheFloorWhateverTheDiskSays() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/ChuteTap.swift"], cwd: "/repo"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: false, tree: "repo")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/ChuteTap.swift"]),
            ],
            belowFloor: { _ in true }
        )

        #expect(lookups == [.indexed, .readWholeAfterDigest(file: "/repo/Sources/App/ChuteTap.swift")])
    }

    /// A `target` with a space in it is one file's path, and its digest decides that file's floor like any other — an old transcript is scored as it always was.
    @Test
    func aSpacedPathTargetDecidesItsFilesFloor() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/My App/ChuteTap.swift"], cwd: "/repo"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/My App/ChuteTap.swift", servedSource: true, tree: "repo")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/My App/ChuteTap.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .belowFloor(file: "/repo/Sources/My App/ChuteTap.swift")])
    }

    /// Several targets weigh too: the verdict an answer carries names its own file, so it is about that file whichever target produced it.
    @Test
    func aSeveralTargetsDigestDecidesTheFloorOfTheFileItsVerdictNames() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["targets": ["Sources/App/ChuteTap.swift", "BayCard"]], cwd: "/repo"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: true, tree: "repo")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/ChuteTap.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .belowFloor(file: "/repo/Sources/App/ChuteTap.swift")])
    }

    /// A digest whose answer is no verdict on the file a later read opens.
    struct UndecidingDigest: CustomTestStringConvertible, Sendable {
        let label: String
        var target = "Sources/App/ChuteTap.swift"
        var offset: Int?
        var signaturesOnly = false
        var answer = TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: false, tree: "repo")
        var read = "/repo/Sources/App/ChuteTap.swift"
        /// Whether the digest was of the file the read opens, which a file sharing only its name is not.
        var ofTheReadFile = true

        var testDescription: String {
            label
        }

        var input: [String: Any] {
            var input: [String: Any] = ["target": target]
            input["offset"] = offset
            input["signaturesOnly"] = signaturesOnly ? true : nil
            return input
        }

        static let all = [
            UndecidingDigest(
                label: "a type's served source",
                target: "ChuteTap",
                answer: "tree: repo  head: 0000000  dirty: 0\nChuteTap — App — Sources/App/ChuteTap.swift:4-15\n"
                    + "(12 lines; a digest would cost 140% of the source\(SourcePassthrough.servedSourceSuffix)\n\nstruct ChuteTap {}"
            ),
            UndecidingDigest(label: "a paged digest", offset: 20),
            UndecidingDigest(label: "signatures only", signaturesOnly: true),
            UndecidingDigest(
                label: "another file of the same name",
                answer: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: true, tree: "repo"),
                read: "/repo/Tests/AppTests/ChuteTap.swift",
                ofTheReadFile: false
            ),
        ]
    }

    /// Only a digest of the file itself decides its floor; a type's digest, a paged one and another file's leave it to the disk.
    ///
    /// A type's served source is its own extents, and a small type can sit in a large file. A paged or signatures-only digest never weighs the source. And a verdict names its file by path, so a file sharing only its name is not the file it was about.
    @Test(arguments: UndecidingDigest.all, [true, false])
    func aDigestOfAnythingButTheFileItselfLeavesTheFloorToTheDisk(digest: UndecidingDigest, onDisk: Bool) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: digest.input, cwd: "/repo"),
                TranscriptFixture.indexAnswer(id: "d1", text: digest.answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": digest.read]),
            ],
            belowFloor: { _ in onDisk }
        )

        let unfloored: SwiftLookup = digest.ofTheReadFile ? .readWholeAfterDigest(file: digest.read) : .cold(file: digest.read, missed: nil)

        #expect(lookups == [.indexed, onDisk ? .belowFloor(file: digest.read) : unfloored])
    }

    /// A verdict is about the file in the repository the digest read, not about the same relative path in another.
    ///
    /// Matched by suffix, a below-floor digest of `Sources/App/Model.swift` in one checkout excused the whole read of that path in a second, larger one.
    @Test
    func aVerdictInOneRepositoryDoesNotDecideTheSamePathInAnother() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/Model.swift"], cwd: "/work/small"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/Model.swift", servedSource: true, tree: "small")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/work/big/Sources/App/Model.swift"]),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/work/small/Sources/App/Model.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/big/Sources/App/Model.swift"),
            .belowFloor(file: "/work/small/Sources/App/Model.swift"),
        ])
    }

    /// A verdict on a repository's root file decides that file alone, not every file of its name.
    ///
    /// Its relative path is the bare file name, and as a suffix that matches any `…/Units.swift` on the machine.
    @Test
    func aVerdictOnARootFileDecidesThatFileAlone() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Units.swift"], cwd: "/work/small"),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Units.swift", servedSource: true, tree: "small")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/work/big/Sources/Units.swift"]),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/work/small/Units.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/big/Sources/Units.swift"),
            .belowFloor(file: "/work/small/Units.swift"),
        ])
    }

    /// The call's `root` argument is what the answer is relative to, whatever directory the call was made in.
    @Test
    func theRootArgumentIsWhatAVerdictIsRelativeTo() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse(
                    "mcp__sift__digest",
                    id: "d1",
                    input: ["target": "Sources/App/Model.swift", "root": "/work/big"],
                    cwd: "/work/small"
                ),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/Model.swift", servedSource: true, tree: "big")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/work/small/Sources/App/Model.swift"]),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/work/big/Sources/App/Model.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/small/Sources/App/Model.swift"),
            .belowFloor(file: "/work/big/Sources/App/Model.swift"),
        ])
    }

    /// Where the digest's root cannot be known, it records no verdict, and the read is left to the disk in both directions.
    @Test(arguments: [true, false])
    func aVerdictWithNoRootToResolveItIsLeftToTheDisk(onDisk: Bool) {
        let read = "/repo/Sources/App/ChuteTap.swift"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/ChuteTap.swift"]),
                TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Sources/App/ChuteTap.swift", servedSource: !onDisk)),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": read]),
            ],
            belowFloor: { _ in onDisk }
        )

        #expect(lookups == [.indexed, onDisk ? .belowFloor(file: read) : .readWholeAfterDigest(file: read)])
    }

    /// An MCP digest answered from another repository's `root` does not credit this repository's own file of the same name — the scan's crediting is keyed by root exactly as the advice ledger keys `digestsAsked`.
    @Test
    func anMCPDigestFromAnotherRootDoesNotCreditThisRepositorysFile() throws {
        try TemporaryDirectory.withScope {
            let here = try MCPTestRepo.make(declaring: "Foo")
            let other = try MCPTestRepo.make(declaring: "Foo")
            let read = here.appendingPathComponent("Foo.swift").path
            let lookups = TranscriptFixture.lookups(
                [
                    TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Foo", "root": other.path], cwd: here.path),
                    TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Foo.swift", servedSource: true, tree: "repoB")),
                    TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": read], cwd: here.path),
                ],
                belowFloor: { _ in false }
            )

            #expect(lookups == [.indexed, .cold(file: read, missed: nil)])
        }
    }

    /// The same digest, answered with no `root` — so it falls back to the repository it was made in — still credits the read that follows, once that repository is the file's own.
    @Test
    func aDigestFromTheSameRootStillCreditsTheFile() throws {
        try TemporaryDirectory.withScope {
            let repo = try MCPTestRepo.make(declaring: "Foo")
            let read = repo.appendingPathComponent("Foo.swift").path
            let lookups = TranscriptFixture.lookups(
                [
                    TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Foo"], cwd: repo.path),
                    TranscriptFixture.indexAnswer(id: "d1", text: TranscriptFixture.fileDigest("Foo.swift", servedSource: true)),
                    TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": read], cwd: repo.path),
                ],
                belowFloor: { _ in false }
            )

            #expect(lookups == [.indexed, .readWholeAfterDigest(file: read)])
        }
    }

    /// The CLI form of the same rule: `sift digest --root <another repository> Foo` does not credit this repository's own `Foo.swift`.
    @Test
    func aShellDigestFromAnotherRootDoesNotCreditThisRepositorysFile() throws {
        try TemporaryDirectory.withScope {
            let here = try MCPTestRepo.make(declaring: "Foo")
            let other = try MCPTestRepo.make(declaring: "Foo")
            let read = here.appendingPathComponent("Foo.swift").path
            let lookups = TranscriptFixture.lookups(
                [
                    TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest --root \(other.path) Foo"], cwd: here.path),
                    TranscriptFixture.toolResult(id: "b1", isError: false),
                    TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": read], cwd: here.path),
                ],
                belowFloor: { _ in false }
            )

            #expect(lookups.last == .cold(file: read, missed: nil))
        }
    }

    /// The lookups a below-floor digest of `path` and reads of it and its namesakes elsewhere come to, for a digest made with `input` from `cwd` whose answer names `tree` in its header — no header at all where `tree` is `nil` — and carries `note` under it; the reads carry a working directory of their own where one is given.
    private static func verdictLookups(
        input: [String: Any] = [:],
        cwd: String,
        tree: String?,
        note: String? = nil,
        path: String = "Sources/App/Model.swift",
        readsFrom: String? = nil,
        reads: [String]
    ) -> [SwiftLookup] {
        var answer = TranscriptFixture.fileDigest(path, servedSource: true, tree: tree ?? "")
        if tree == nil {
            answer = answer.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        }
        if let note {
            answer = answer.replacingOccurrences(of: "parse_errors: 0\n", with: "parse_errors: 0\n\(note)\n")
        }
        var digestInput = input
        digestInput["target"] = path
        return TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: digestInput, cwd: cwd),
                TranscriptFixture.indexAnswer(id: "d1", text: answer),
            ] + reads.enumerated().map { index, read in
                TranscriptFixture.toolUse("Read", id: "r\(index)", input: ["file_path": read], cwd: readsFrom)
            },
            belowFloor: { _ in false }
        )
    }

    /// An answer's path is relative to the repository the engine resolved, not to the directory the call was made from: a context that has moved into `Sources/` is answered `Sources/App/Model.swift` all the same, and the read of that file is decided by it.
    @Test
    func aVerdictFromInsideTheRepositoryDecidesItsFile() {
        let lookups = Self.verdictLookups(cwd: "/repo/Sources", tree: "repo", reads: ["/repo/Sources/App/Model.swift"])

        #expect(lookups == [.indexed, .belowFloor(file: "/repo/Sources/App/Model.swift")])
    }

    /// The same for a `root` argument naming a directory inside the repository, which the engine resolves up to the repository.
    @Test
    func aVerdictRootedInsideTheRepositoryDecidesItsFile() {
        let lookups = Self.verdictLookups(input: ["root": "/repo/Sources"], cwd: "/elsewhere", tree: "repo", reads: ["/repo/Sources/App/Model.swift"])

        #expect(lookups == [.indexed, .belowFloor(file: "/repo/Sources/App/Model.swift")])
    }

    /// A sibling checkout is neither the directory the call was made from nor one above it, so its file of the same relative path is not decided, whether the call was made from the repository's root or from inside it.
    @Test(arguments: ["/work/small", "/work/small/Sources"])
    func aVerdictFromInsideOneRepositoryDoesNotDecideAnother(cwd: String) {
        let lookups = Self.verdictLookups(
            cwd: cwd,
            tree: "small",
            reads: ["/work/big/Sources/App/Model.swift", "/work/small/Sources/App/Model.swift"]
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/big/Sources/App/Model.swift"),
            .belowFloor(file: "/work/small/Sources/App/Model.swift"),
        ])
    }

    /// A call made from above every repository is answered from the one it resolved to, and the answer says which: that is the repository its path is relative to, and no other beside it.
    @Test
    func aVerdictFromAboveTheRepositoriesIsRelativeToTheOneItResolvedTo() throws {
        let note = try #require(ResolvedRoot.enclosedSole(URL(fileURLWithPath: "/work/big"), from: "/work").note)
        let lookups = Self.verdictLookups(
            cwd: "/work",
            tree: "big",
            note: note,
            reads: ["/work/small/Sources/App/Model.swift", "/work/big/Sources/App/Model.swift"]
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/small/Sources/App/Model.swift"),
            .belowFloor(file: "/work/big/Sources/App/Model.swift"),
        ])
    }

    /// A worktree nests inside the checkout it was cut from, so the directories above a worktree's call include that checkout — a different tree, which the answer's header rules out by naming the worktree: its own copy of the file is decided, and the checkout's copy is not.
    @Test(arguments: ["/repo/.claude/worktrees/a", "/repo/.claude/worktrees/a/Sources"])
    func aWorktreesVerdictDoesNotDecideTheCheckoutItNestsIn(cwd: String) {
        let lookups = Self.verdictLookups(
            cwd: cwd,
            tree: "repo (worktree a)",
            reads: ["/repo/Sources/App/Model.swift", "/repo/.claude/worktrees/a/Sources/App/Model.swift"]
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/repo/Sources/App/Model.swift"),
            .belowFloor(file: "/repo/.claude/worktrees/a/Sources/App/Model.swift"),
        ])
    }

    /// The other way round: a call from inside a worktree answered by the checkout it nests in — a server rooted there, asked with no `root` — is about the checkout's copy, which the header names, and never the worktree's, though the worktree is where the call was made.
    @Test(arguments: ["/repo/.claude/worktrees/a", "/repo/.claude/worktrees/a/Sources"])
    func aCheckoutsVerdictDoesNotDecideTheWorktreeThatAskedIt(cwd: String) {
        let lookups = Self.verdictLookups(
            cwd: cwd,
            tree: "repo",
            reads: ["/repo/.claude/worktrees/a/Sources/App/Model.swift", "/repo/Sources/App/Model.swift"]
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/repo/.claude/worktrees/a/Sources/App/Model.swift"),
            .belowFloor(file: "/repo/Sources/App/Model.swift"),
        ])
    }

    /// A project whose sources sit in a folder named like the repository: the call is made from that folder, and the answer's path, relative to the repository above it, starts with the folder's name.
    @Test
    func aVerdictFromASourceFolderNamedLikeItsRepositoryDecidesItsFile() {
        let lookups = Self.verdictLookups(
            cwd: "/work/Orchard/Orchard",
            tree: "Orchard",
            path: "Orchard/Model.swift",
            reads: ["/work/Orchard/Orchard/Model.swift"]
        )

        #expect(lookups == [.indexed, .belowFloor(file: "/work/Orchard/Orchard/Model.swift")])
    }

    /// A volume that ignores case holds one directory under every spelling of its name, so a call made from `/work/depot` and answered `tree: Depot` decides the read of that file however either is cased; a volume that heeds case holds two directories, and a spelling that differs decides nothing.
    ///
    /// Asked of the volume these paths would sit on, so the expectation follows the machine the suite runs on; `FloorVerdictTests` pins both policies on any volume.
    @Test(arguments: ["/work/depot", "/work/depot/Sources"], ["/work/Depot/Sources/App/Model.swift", "/work/depot/Sources/App/Model.swift"])
    func aVerdictIsPlacedWithoutRegardToCaseWhereTheVolumeIgnoresIt(cwd: String, read: String) {
        let lookups = Self.verdictLookups(cwd: cwd, tree: "Depot", reads: [read])
        let caseSensitive = FloorVerdict.volumeIsCaseSensitive(at: cwd)

        #expect(lookups == [.indexed, caseSensitive ? .readWholeAfterDigest(file: read) : .belowFloor(file: read)])
    }

    /// A context that moves to another checkout of the same directory name after its digest has not moved the answer with it: the new checkout is not where the call was made, or above it.
    @Test
    func aVerdictDoesNotFollowTheContextIntoACheckoutOfTheSameName() {
        let lookups = Self.verdictLookups(
            cwd: "/work/orchard/app",
            tree: "app",
            readsFrom: "/work/meadow/app",
            reads: ["/work/meadow/app/Sources/App/Model.swift", "/work/orchard/app/Sources/App/Model.swift"]
        )

        #expect(lookups == [
            .indexed,
            .readWholeAfterDigest(file: "/work/meadow/app/Sources/App/Model.swift"),
            .belowFloor(file: "/work/orchard/app/Sources/App/Model.swift"),
        ])
    }

    /// The header is the only evidence of which directory above the call answered, so where it cannot be read a verdict decides the file under the call's own directory and under nothing above it.
    @Test
    func aVerdictWhoseHeaderCannotBeReadDecidesOnlyUnderItsOwnDirectory() {
        let fromInside = Self.verdictLookups(cwd: "/repo/Sources", tree: nil, reads: ["/repo/Sources/App/Model.swift"])
        let fromTheRoot = Self.verdictLookups(cwd: "/repo", tree: nil, reads: ["/repo/Sources/App/Model.swift"])

        #expect(fromInside == [.indexed, .readWholeAfterDigest(file: "/repo/Sources/App/Model.swift")])
        #expect(fromTheRoot == [.indexed, .belowFloor(file: "/repo/Sources/App/Model.swift")])
    }

    /// A header that names another tree says the checkout that answered is somewhere else, so not even the call's own directory is decided.
    @Test(arguments: ["/repo", "/repo/Sources"])
    func aVerdictDecidesNoDirectoryNamedOtherThanItsTree(cwd: String) {
        let lookups = Self.verdictLookups(cwd: cwd, tree: "elsewhere", reads: ["/repo/Sources/App/Model.swift"])

        #expect(lookups == [.indexed, .readWholeAfterDigest(file: "/repo/Sources/App/Model.swift")])
    }

    /// The stated residual: a call made from a checkout whose directory has the name of the tree that answered it — a linked worktree named exactly like its repository, one `app` answered by another — carries nothing in the transcript that tells the two apart, and its verdict decides the calling checkout's copy.
    ///
    /// Pinned as it stands, so a rule that learns to tell them apart fails here rather than going unnoticed.
    @Test(arguments: [
        (cwd: "/repo/.claude/worktrees/repo", tree: "repo", read: "/repo/.claude/worktrees/repo/Sources/App/Model.swift"),
        (cwd: "/work/meadow/app", tree: "app", read: "/work/meadow/app/Sources/App/Model.swift"),
    ])
    func aCheckoutNamedLikeTheTreeThatAnsweredIsTakenForIt(cwd: String, tree: String, read: String) {
        let lookups = Self.verdictLookups(cwd: cwd, tree: tree, reads: [read])

        #expect(lookups == [.indexed, .belowFloor(file: read)])
    }

    /// The same residual the other way round: a worktree named exactly like its repository answers its own digest, but the header names only `repo` once the `(worktree repo)` annotation is read back off, and the main checkout it nests in carries that same directory name — so its copy of the file is taken for the worktree's own.
    ///
    /// Pinned as it stands: a known residual that rounds the share up.
    @Test
    func aWorktreeNamedLikeItsRepositoryIsTakenForTheCheckoutItNestsIn() {
        let lookups = Self.verdictLookups(
            cwd: "/repo/.claude/worktrees/repo",
            tree: "repo (worktree repo)",
            path: "Sources/M.swift",
            reads: ["/repo/Sources/M.swift"]
        )

        #expect(lookups == [.indexed, .belowFloor(file: "/repo/Sources/M.swift")])
    }
}

// MARK: - Shell windows into a file already open

extension TranscriptScanTests {
    /// The windowed shell reads a ranged `Read` is spelled as, each into one relative path.
    static let shellWindows = [
        "sed -n '120,160p' Sources/App/FeedState.swift",
        "head -40 Sources/App/FeedState.swift",
        "tail -20 Sources/App/FeedState.swift",
    ]

    /// A shell window into a file already open in the context is a re-read, exactly as the same window through `Read` is.
    ///
    /// The shell branch never asked whether the file was open, so every re-window of a file in context counted as a lookup that went around the index — while the identical re-read through `Read` counted as the re-read it is. Two spellings of one read cannot be scored two ways.
    @Test(arguments: shellWindows)
    func aShellWindowIntoAnOpenFileIsARereadAsTheSameReadWouldBe(command: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/FeedState.swift", "offset": 120], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
            .revisited(file: "Sources/App/FeedState.swift"),
            .revisited(file: "/repo/Sources/App/FeedState.swift"),
        ])
    }

    /// A window opens the file for the windows and ranged reads that follow it, in either spelling, and each of those is a re-read.
    @Test(arguments: shellWindows)
    func aShellWindowOpensTheFileForWhateverFollowsIt(command: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": command], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift", "offset": 120], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
            .revisited(file: "Sources/App/FeedState.swift"),
            .revisited(file: "/repo/Sources/App/FeedState.swift"),
        ])
    }

    /// On a file nothing in the context has opened, the same windows are scored as they always were — even beside another file that is open.
    @Test(arguments: shellWindows)
    func aShellWindowIntoAnUnopenedFileIsScoredAsBefore(command: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/YardView.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Sources/App/YardView.swift", missed: nil),
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
        ])
    }

    /// An absolute path needs no working directory to be recognised as the open file.
    @Test
    func anAbsoluteShellWindowIntoAnOpenFileIsARereadWithoutADirectory() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"]),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '1,30p' /repo/Sources/App/FeedState.swift"]),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
            .revisited(file: "/repo/Sources/App/FeedState.swift"),
        ])
    }

    /// A relative window behind a `cd` in the same command is not known to be the open file, so it is scored as it always was.
    ///
    /// The line's directory is not where the path is relative to, and guessing that it is would excuse a lookup because a different file of the same relative name was open — the share rounding up on a guess.
    @Test
    func aRelativeWindowBehindACdIsNotTakenForTheOpenFile() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd Kit && sed -n '1,30p' Sources/App/FeedState.swift"], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
        ])
    }

    /// A relative window behind literal `cd`s is spelled out against where they move — one after another, or an absolute one — as the hook places it, so a window into the file a `Read` opened is a re-read, exactly as the same window without the `cd`s would be.
    @Test(arguments: [
        ("cd Kit && sed -n '1,30p' Sources/App/FeedState.swift", "Sources/App/FeedState.swift"),
        ("cd Kit/Sources && cd App && sed -n '1,30p' FeedState.swift", "FeedState.swift"),
        ("cd /repo/Kit/Sources/App && sed -n '1,30p' FeedState.swift", "FeedState.swift"),
    ])
    func aRelativeWindowBehindLiteralCdsIsTheFileTheyMoveTo(command: String, written: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Kit/Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Kit/Sources/App/FeedState.swift", missed: nil),
            .revisited(file: written),
        ])
    }

    /// Every other way a command moves directory before its window runs: a brace group, a subshell with and without a space, and `cd` behind `builtin` or `command`, or spelled `pushd`.
    static let directoryChanges = [
        "{ cd Kit; sed -n '1,30p' Sources/App/FeedState.swift; }",
        "( cd Kit; sed -n '1,30p' Sources/App/FeedState.swift )",
        "(cd Kit && sed -n '1,30p' Sources/App/FeedState.swift )",
        "builtin cd Kit && sed -n '1,30p' Sources/App/FeedState.swift",
        "command cd Kit && sed -n '1,30p' Sources/App/FeedState.swift",
        "pushd Kit && sed -n '1,30p' Sources/App/FeedState.swift",
    ]

    /// A relative window behind any spelling of a directory change is not known to be the open file, exactly as behind a bare `cd`.
    ///
    /// Read off the first token, each of these missed the `cd` and spelled the path out against the line's directory, so a window into `Kit`'s file was scored a re-read of the one open in the repository root.
    @Test(arguments: directoryChanges)
    func aRelativeWindowBehindAnySpellingOfADirectoryChangeIsNotTakenForTheOpenFile(command: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
        ])
    }

    /// A window that failed put nothing in context, so it opens nothing: the read after it is still a first touch.
    ///
    /// The read is ranged, because a ranged read is the one a window that succeeded would have made a re-read.
    @Test
    func aFailedShellWindowOpensNothing() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '1,30p' Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolResult(id: "b1", isError: true, text: "sed: Sources/App/FeedState.swift: No such file or directory"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift", "offset": 1, "limit": 30], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
        ])
    }

    /// A window after a digest does not make the whole read that follows a re-read: that read is the one the digest exists to save, paid in full.
    ///
    /// Scored as a re-read it left the denominator, so a digest, a five-line window and a whole read of the same file raised the share on the strength of the five lines.
    @Test(arguments: shellWindows)
    func aShellWindowDoesNotExcuseAWholeReadAfterItsDigest(command: String) {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredDigest("FeedState", id: "d1", file: "Sources/App/FeedState.swift") + [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .indexed,
            .guided(file: "Sources/App/FeedState.swift"),
            .readWholeAfterDigest(file: "/repo/Sources/App/FeedState.swift"),
        ])
    }

    /// With no digest before it, the whole read after a window is cold: the window showed some lines, and the read took the file.
    @Test(arguments: shellWindows)
    func aShellWindowDoesNotExcuseAWholeReadWithNoDigest(command: String) {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
        ])
    }

    /// A whole read after a window does open the file in full, so whatever reads it next, in either spelling, is a re-read.
    @Test
    func aWholeReadAfterAWindowOpensTheFileForWhatFollows() {
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '1,5p' Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/FeedState.swift"], cwd: "/repo"),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .cold(file: "Sources/App/FeedState.swift", missed: nil),
            .cold(file: "/repo/Sources/App/FeedState.swift", missed: nil),
            .revisited(file: "/repo/Sources/App/FeedState.swift"),
        ])
    }
}

// MARK: - Contexts that could not reach the index

extension TranscriptScanTests {
    /// A refusal is counted as advice delivered as well as taken back off the tally, because the two are different facts.
    ///
    /// The retraction says the lookup did not happen. The count says the context was told what to call — and a run of those with never an index call between them is the only thing a transcript records about whether the tools were there to call at all. Counted for a *read* as much as for a search, though a read opens no escape hatch: this measures the advice, and a context with no index tools takes its refusals on both.
    @Test
    func aRefusalIsCountedAsAdviceDeliveredAsWellAsTakenBackOffTheTally() {
        let tally = TranscriptFixture.tally(TranscriptFixture.refusedRead(1) + TranscriptFixture.refusedRead(2))

        #expect(tally.refusals == 2)
        // The reads themselves never happened, so they are in no bucket at all.
        #expect(tally.cold == 0)
        #expect(tally.total == 0)
    }

    /// An error from anywhere else is not this tool speaking, and counting it would let the verdict rest on tools failing.
    ///
    /// A permission prompt declined, a timeout and a missing file are all `is_error` too. The offer line is what tells a refusal apart, exactly as it does for the escape hatch.
    @Test
    func anErrorThatIsNotARefusalIsNotCountedAsOne() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/SummaryState.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: true, text: "The user doesn't want to proceed with this tool use."),
        ])

        #expect(tally.refusals == 0)
    }

    /// A context refused a dozen times over that never once calls the index could not reach it, and its cold lookups are scored apart rather than against the share.
    ///
    /// Asked of the whole context, at the moment the tally is read, and never as each lookup is classified — which is what lets one index call lift it again with nothing to unwind.
    @Test
    func aContextRefusedOverAndOverWithNoIndexCallIsScoredApart() {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead)
        let read = [TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"])]

        let tally = TranscriptFixture.tally(refusals + read)

        #expect(tally.couldNotReachTheIndex)
        #expect(tally.scored == TranscriptTally(cold: 0, refusals: TranscriptTally.refusalsWithoutAnIndexCall, unreachable: 1))
        #expect(tally.scored.total == 0)

        // And one index call anywhere in the same context settles it the other way, whatever came before.
        let reached = TranscriptFixture.tally(refusals + read + [TranscriptFixture.toolUse("mcp__sift__where", id: "w1")])
        #expect(!reached.couldNotReachTheIndex)
        #expect(reached.scored.cold == 1)
        #expect(reached.scored.unreachable == 0)
    }

    /// A context that reached the index on the CLI reached it, which is exactly what the diagnosis told it to do.
    ///
    /// The worked example: a subagent pinned to `tools: Read, Grep, Glob, Bash` takes twelve refusals, is told *"where Bash is available the same answers are on the CLI"*, and does it. The advice hook counts that and puts the advice back; a scan that could not see a Bash `sift` call would go on calling the context unreachable and moving its later cold lookups out of the denominator — which *raises* the share, the one direction this may never round.
    ///
    /// The lookup it served counts in the share too, on its own row inside `indexed`: the route is not what the share asks about.
    @Test
    func aContextThatReachedTheIndexOnTheCLIIsNeverUnreachable() {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead)
        let read = [TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"])]
        let cli = [TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift where SummaryState"])]

        let tally = TranscriptFixture.tally(refusals + cli + read)

        #expect(tally.cliCalls == 1)
        // The index served a lookup, by the only route this context had.
        #expect(tally.indexed == 1)
        #expect(tally.cliServed == 1)
        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 1)
        #expect(tally.scored.unreachable == 0)
    }

    /// A lookup the CLI served counts in the share exactly as the same lookup through the MCP tools does.
    ///
    /// The shape of the defect this pins: a session under an output style that mandates the Bash tool reaches the index almost entirely through the CLI, and every one of those was invisible to the share — it neither raised nor lowered it, so there was no telling a genuine miss from the index answering off-camera. Three lookups here, two of them served, whichever face served them.
    @Test
    func aLookupTheCLIServedCountsTowardsTheShareLikeAnyOther() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]),
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift where SummaryState"]),
            TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"]),
        ])

        #expect(tally.indexed == 2)
        #expect(tally.cliServed == 1)
        #expect(tally.cold == 1)
        #expect(tally.total == 3)
        #expect(tally.shareText == "67%")
    }

    /// One Bash call that both reaches the index and goes around it is counted as both, because a cold lookup taken out of the denominator raises the share.
    ///
    /// The advice hook returns on the first half — it may not deny anything on a call that is also an index call — so this grep is a miss the metric sees and the hook cannot. That divergence is deliberate and named in both places. The alternative is a denominator that quietly drops its awkward cases, which is not a floor.
    @Test
    func aCallThatBothReachesTheIndexAndGoesAroundItIsCountedAsBoth() {
        let compound = [TranscriptFixture.toolUse(
            "Bash",
            id: "b1",
            input: ["command": "sift where SummaryState; grep -rn --include=*.swift Reducer Sources"]
        )]

        let tally = TranscriptFixture.tally(compound)

        #expect(tally.cliCalls == 1)
        #expect(tally.cold == 1)
        // Both halves are lookups, and both are counted: the `where` the index served and the grep that went around it.
        #expect(tally.indexed == 1)
        #expect(tally.cliServed == 1)
        #expect(tally.total == 2)
    }

    /// A build wrapped in `sift run` is the tool being used too, exactly as the advice hook reads it.
    @Test
    func aWrappedRunCountsAsReachingTheIndexJustAsTheHookCountsIt() {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead)
        let wrapped = [TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd Kit && sift run -- swift test"])]

        let tally = TranscriptFixture.tally(refusals + wrapped)

        #expect(tally.cliCalls == 1)
        #expect(!tally.couldNotReachTheIndex)
    }

    /// A wrapped build is not a lookup, so it enters neither half of the share — the separation the CLI-served count rests on.
    ///
    /// `cliCalls` counts every subcommand, because any of them proves the binary was on this context's path; only the four that answer a question about Swift may reach the numerator. Reading `invokesSift` as both would have scored every build this repository's own sessions wrap as an index lookup.
    @Test(arguments: ["sift run -- swift build", "cd Kit && sift run -- xcodebuild test", "sift status", "sift servers"])
    func aSubcommandThatAnswersNoLookupCountsNowhereInTheShare(command: String) {
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command])])

        #expect(tally.cliCalls == 1)
        #expect(tally.indexed == 0)
        #expect(tally.cliServed == 0)
        #expect(tally.total == 0)
        #expect(tally.share == nil)
    }

    /// Searching *for* the word is not using the tool — the mistake that is easiest to make in the one repository named after it.
    @Test
    func namingTheToolInASearchIsNotReachingTheIndex() {
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead)
        let search = [TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -rn sift Sources/App/SummaryState.swift"])]

        let tally = TranscriptFixture.tally(refusals + search)

        #expect(tally.cliCalls == 0)
        #expect(tally.couldNotReachTheIndex)
    }

    /// An index call that failed still proves the tools were there, so the context is judged on its lookups like any other.
    ///
    /// `failed` sits beside `indexed` in the verdict because a call that errored is retracted from `indexed` on its way out: without it, a context whose every call failed reads as one that never called.
    @Test
    func aContextWhoseIndexCallsAllFailedStillReachedTheIndex() {
        let tally = TranscriptFixture.tally(
            (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead) + [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1"),
                TranscriptFixture.toolResult(id: "d1", isError: true, text: "no repository is indexed at that root"),
                TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"]),
            ]
        )

        #expect(tally.indexed == 0)
        #expect(tally.failed == 1)
        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 1)
    }

    /// The harness's own wording for a call it answered in place of delivering because the tool was not there, in each shape it takes.
    static let undeliveredCallErrors = [
        "<tool_use_error>Error: No such tool available: mcp__sift__digest. Its MCP server 'sift' is not available in this context. Continue without this tool.</tool_use_error>",
        "<tool_use_error>Error: No such tool available: mcp__sift__where</tool_use_error>",
    ]

    /// The harness's own wording for a call the auto-mode permission classifier could not rule on in time.
    static let permissionTimeoutError =
        "claude-sonnet-5[1m] is temporarily unavailable (timed out), so auto mode cannot determine the safety of mcp__sift__digest right now. "
            + "Wait a moment and then try this action again. If it keeps failing, continue with other tasks that don't require this action and come back to it later."

    /// A call the harness answered itself never reached the index, so it is not the index failing.
    ///
    /// Filed as `failed` it would be reported against the tool as a defect, and worse, it would prove access: a failed call counts as reaching, so the context that could not reach the index would be the one context never judged so.
    @Test(arguments: undeliveredCallErrors)
    func aCallTheHarnessNeverDeliveredIsUnavailableRatherThanFailed(error: String) {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: error),
        ])

        #expect(tally == TranscriptTally(unavailable: 1))
    }

    /// Undelivered calls are evidence the tool was not there, and count towards the verdict beside the refusals.
    ///
    /// The shape that went unexcused: a dozen refusals, not one call that got through, and two calls the harness never delivered — which, read as failures, kept every cold lookup in the context scored against the share.
    @Test
    func undeliveredCallsFeedTheVerdictThatAContextCouldNotReachTheIndex() {
        let read = [TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"])]
        let undelivered = Self.undeliveredCallErrors.enumerated().flatMap { index, error in
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "u\(index)", input: ["target": "SummaryState"]),
                TranscriptFixture.toolResult(id: "u\(index)", isError: true, text: error),
            ]
        }

        let refusedThroughout = TranscriptFixture.tally(
            (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead) + undelivered + read
        )
        #expect(refusedThroughout.failed == 0)
        #expect(refusedThroughout.couldNotReachTheIndex)
        #expect(refusedThroughout.scored.unreachable == 1)

        // Below the floor on refusals alone, and over it with the two the harness turned away.
        let short = TranscriptTally.refusalsWithoutAnIndexCall - 2
        let refusedShort = TranscriptFixture.tally((0 ..< short).flatMap(TranscriptFixture.refusedRead) + read)
        #expect(!refusedShort.couldNotReachTheIndex)
        let turnedAway = TranscriptFixture.tally((0 ..< short).flatMap(TranscriptFixture.refusedRead) + undelivered + read)
        #expect(turnedAway.couldNotReachTheIndex)
    }

    /// The harness's own wording for a call the user declined at the permission prompt.
    static let declinedCallError = "The user doesn't want to proceed with this tool use. The tool use was rejected "
        + "(eg. if it was a file edit, the new_string was NOT written to the file). "
        + "STOP what you are doing and wait for the user to tell you how to proceed."

    /// A call the user declined is the user's answer, not the index's: no failure, no miss, and no call.
    ///
    /// Filed as `failed` it would be reported against the tool as a defect; counted as `indexed` it would score a lookup nothing served; and it went around nothing, so it is no miss either.
    @Test
    func aCallTheUserDeclinedIsNeitherAFailureNorAMissNorACall() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "SummaryState"]),
            TranscriptFixture.toolResult(id: "w1", isError: true, text: Self.declinedCallError),
        ])

        #expect(tally == TranscriptTally(declined: 1))
        #expect(tally.total == 0)
    }

    /// A declined call proves the context held the tool, since the harness asks only about a tool it has — so it keeps the context out of `unreachable`, as a failed call does.
    ///
    /// Taken the other way it would excuse a context that provably had the index, moving its cold lookups out of the share and raising it.
    @Test
    func aDeclinedCallKeepsAContextFromBeingJudgedUnreachable() {
        let declined = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: Self.declinedCallError),
        ]
        let read = [TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Units.swift"])]

        let tally = TranscriptFixture.tally(
            (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead) + declined + read
        )

        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 1)
        #expect(tally.scored.unreachable == 0)
    }

    /// A call the auto-mode classifier could not rule on in time was stopped at the permission check, as a declined one is: no failure, no miss, no call, and not the tool being absent.
    ///
    /// The classifier rules only on a tool the context holds, so filing its timeout beside `No such tool available` would count a sign of access as evidence against it.
    @Test
    func aPermissionCheckThatCouldNotRuleIsDeclinedRatherThanUnavailable() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "SummaryState"]),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: Self.permissionTimeoutError),
        ])

        #expect(tally == TranscriptTally(declined: 1))
        #expect(tally.total == 0)
    }

    /// Timeouts at the permission check are no evidence the context lacked the tool, so they cannot carry a context of refusals over the floor and take its misses out of the share.
    ///
    /// Ten refusals and two timeouts with not one call through: read as undelivered, the two timeouts made twelve and moved all five cold reads out of the share, turning a 0% share into none at all.
    @Test
    func permissionTimeoutsDoNotFeedTheVerdictThatAContextCouldNotReachTheIndex() {
        let refusals = (0 ..< 10).flatMap(TranscriptFixture.refusedRead)
        let timeouts = (0 ..< 2).flatMap { index in
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "p\(index)", input: ["target": "SummaryState"]),
                TranscriptFixture.toolResult(id: "p\(index)", isError: true, text: Self.permissionTimeoutError),
            ]
        }
        let reads = (0 ..< 5).map { index in
            TranscriptFixture.toolUse("Read", id: "c\(index)", input: ["file_path": "/repo/Cold\(index).swift"])
        }

        let tally = TranscriptFixture.tally(refusals + timeouts + reads)

        #expect(tally.declined == 2)
        #expect(tally.unavailable == 0)
        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 5)
        #expect(tally.scored.unreachable == 0)
        #expect(tally.scored.share == 0)
    }
}

// MARK: - #36.1's cwd threading, pinned at the call sites

extension TranscriptScanTests {
    /// The re-run's shape, from the sole `.refusalFollowUp(.reRun...)` event a line sequence produces — `nil` where there is not exactly one.
    private static func soleReRunShape(_ lines: [Data]) -> RefusalShape? {
        var state = TranscriptScanState()
        let shapes = lines.flatMap { TranscriptScan.events(line: $0, state: &state) }.compactMap { event -> RefusalShape? in
            guard case let .refusalFollowUp(.reRun(shape, _), _) = event else { return nil }
            return shape
        }
        return shapes.count == 1 ? shapes[0] : nil
    }

    /// Pins #36.1's `cwd` threading at the tool-use classifier's call site for a refused whole `Read` (`refusedCallShape(read:cwd:)`, ~332) — dropping `cwd: directory` there breaks no other test.
    ///
    /// A whole read from a repository that merely sits inside a directory named `checkouts` must come out as a whole-file read, not `outsideIndexedSources`, and only the call's own `cwd` decides that.
    @Test
    func aRefusedReadsCwdDecidesItsReRunsShape() {
        let path = "/Users/x/checkouts/App/Sources/View.swift"
        let cwd = "/Users/x/checkouts/App"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let lines = [
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": path], turn: "m1", usage: usage, cwd: cwd),
            TranscriptTurns.result(id: "r1", text: TranscriptFixture.refusal(call: "digest View"), isError: true),
            TranscriptTurns.call("Read", id: "r2", input: ["file_path": path], turn: "m2", usage: usage, cwd: cwd),
        ]

        #expect(Self.soleReRunShape(lines) == .wholeFileRead)
    }

    /// The same classifier's call site for `Grep`/`Glob` (~369): a `path=` argument inside the same `checkouts`-named repository is judged by the call's own `cwd`, not by the raw path alone.
    @Test
    func aRefusedGrepsCwdDecidesItsReRunsShape() {
        let cwd = "/Users/x/checkouts/App"
        let input: [String: Any] = ["output_mode": "content", "pattern": "SummaryState", "path": "/Users/x/checkouts/App/Sources", "glob": "*.swift"]
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let lines = [
            TranscriptTurns.call("Grep", id: "g1", input: input, turn: "m1", usage: usage, cwd: cwd),
            TranscriptTurns.result(id: "g1", text: TranscriptFixture.refusal(call: "where SummaryState"), isError: true),
            TranscriptTurns.call("Grep", id: "g2", input: input, turn: "m2", usage: usage, cwd: cwd),
        ]

        #expect(Self.soleReRunShape(lines) == .other)
    }

    /// And for a shell `grep` (`refusedCallShape(bash:cwd:)`, ~442/474/496): the same repository, the same call's `cwd`, reached through `Bash` instead.
    @Test
    func aRefusedShellGrepsCwdDecidesItsReRunsShape() {
        let cwd = "/Users/x/checkouts/App"
        let command = "grep -n SummaryState /Users/x/checkouts/App/Sources/View.swift"
        let usage = TranscriptTurns.Usage(cacheRead: 1000)
        let lines = [
            TranscriptTurns.call("Bash", id: "b1", input: ["command": command], turn: "m1", usage: usage, cwd: cwd),
            TranscriptTurns.result(id: "b1", text: TranscriptFixture.refusal(call: "where SummaryState"), isError: true),
            TranscriptTurns.call("Bash", id: "b2", input: ["command": command], turn: "m2", usage: usage, cwd: cwd),
        ]

        #expect(Self.soleReRunShape(lines) == .other)
    }

    /// The scan remembers an answer to a line of several lookups under the key the hook answered, which is the first lookup it had not already answered: after `A` and then `A && B` are answered, `B` run alone is the answer's re-run, never a cold miss.
    @Test
    func anAnswerToACompoundLineIsRememberedUnderTheLookupItAnswered() {
        let first = #"grep -n 'static\|case ' /repo/Sources/App/Depot.swift"#
        let second = #"grep -n 'static\|case ' /repo/Sources/App/Gadget.swift"#
        let answered = { (file: String) in
            InPlaceAnswer.reason(
                calls: ["digest Sources/App/\(file)"],
                answer: TranscriptFixture.fileDigest("Sources/App/\(file)", servedSource: false),
                source: 12000,
                standsIn: ""
            ).text
        }
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": first], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: answered("Depot.swift"), isError: true),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": "\(first) && \(second)"], turn: "m2", cwd: "/repo"),
            TranscriptTurns.result(id: "c2", text: answered("Gadget.swift"), isError: true),
            TranscriptTurns.call("Bash", id: "c3", input: ["command": second], turn: "m3", cwd: "/repo"),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
        #expect(TranscriptFixture.tally(lines).cold == 0)
    }

    /// Calls sent together are scored in the order the hook judged them, each after the answer the one before it drew: `A` and `A && B` in one turn are answered on `A` and then on `B`, so a later `B` alone, or `A && B` again, is the answer's re-run rather than a fresh lookup.
    @Test(arguments: [false, true])
    func aCompoundLineSentBesideItsFirstLookupIsRememberedUnderTheSecond(rerunsWholeLine: Bool) {
        let first = #"grep -n 'static\|case ' /repo/Sources/App/Depot.swift"#
        let second = #"grep -n 'static\|case ' /repo/Sources/App/Gadget.swift"#
        let answered = { (file: String) in
            InPlaceAnswer.reason(
                calls: ["digest Sources/App/\(file)"],
                answer: TranscriptFixture.fileDigest("Sources/App/\(file)", servedSource: false),
                source: 12000,
                standsIn: ""
            ).text
        }
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": first], turn: "m1", cwd: "/repo"),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": "\(first) && \(second)"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: answered("Depot.swift"), isError: true),
            TranscriptTurns.result(id: "c2", text: answered("Gadget.swift"), isError: true),
            TranscriptTurns.call("Bash", id: "c3", input: ["command": rerunsWholeLine ? "\(first) && \(second)" : second], turn: "m2", cwd: "/repo"),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
        let tally = TranscriptFixture.tally(lines)
        #expect(tally.cold == 0 && tally.withheldOnWorth == 1)
        #expect(tally.indexed == 2 && tally.answered == 2)
    }

    /// The same search sent twice in one turn is refused once and let through the second time, as the hook judged the two in order — so the second is the escape hatch, though the refusal is written after it.
    @Test
    func aSearchRepeatedInTheSameTurnIsTheReRunOfTheFirst() {
        let search: [String: Any] = ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]
        let lines = [
            TranscriptTurns.call("Grep", id: "g1", input: search, turn: "m1"),
            TranscriptTurns.call("Grep", id: "g2", input: search, turn: "m1"),
            TranscriptTurns.result(id: "g1", text: TranscriptFixture.refusal(), isError: true),
            TranscriptTurns.result(id: "g2", text: "Sources/App/SummaryState.swift:12"),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
        let tally = TranscriptFixture.tally(lines)
        #expect(tally.withheldOnWorth == 1 && tally.cold == 0)
    }

    /// A lookup the hook let through leaves nothing answered, so a compound line sent beside it in the same turn was judged on that same first lookup — and an answer to the line is remembered under it, making a later run of it alone the answer's re-run.
    @Test
    func aCompoundLineSentBesideALookupTheHookLetThroughIsRememberedUnderTheFirst() {
        let first = #"grep -n 'static\|case ' /repo/Sources/App/Depot.swift"#
        let second = #"grep -n 'static\|case ' /repo/Sources/App/Gadget.swift"#
        let answered = InPlaceAnswer.reason(
            calls: ["digest Sources/App/Depot.swift", "digest Sources/App/Gadget.swift"],
            answer: "\(TranscriptFixture.fileDigest("Sources/App/Depot.swift", servedSource: false))\n\n"
                + TranscriptFixture.fileDigest("Sources/App/Gadget.swift", servedSource: false),
            source: 12000,
            standsIn: "",
            wholeCommand: true,
            lookups: 2
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": first], turn: "m1", cwd: "/repo"),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": "\(first) && \(second)"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: "12:    static let shared = Depot()"),
            TranscriptTurns.result(id: "c2", text: answered, isError: true),
            TranscriptTurns.call("Bash", id: "c3", input: ["command": first], turn: "m2", cwd: "/repo"),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
        let tally = TranscriptFixture.tally(lines)
        // Not `tally.indexed == 1 && tally.answered == 1`: that pair comes from c2's own answered-in-place
        // credit, which fires whether or not the earlier call's fallback is settled correctly, and is
        // already pinned by InPlaceAccountingTests — it would pass with the let-through fallback removed.
        #expect(tally.cold == 1 && tally.withheldOnWorth == 1)
    }

    /// The same search sent twice in one turn, the first let through, is two lookups the hook let run: the second is no re-run of a refusal that never happened.
    @Test
    func aSearchRepeatedInTheSameTurnAfterTheHookLetItThroughIsCold() {
        let search: [String: Any] = ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]
        let lines = [
            TranscriptTurns.call("Grep", id: "g1", input: search, turn: "m1"),
            TranscriptTurns.call("Grep", id: "g2", input: search, turn: "m1"),
            TranscriptTurns.result(id: "g1", text: "Sources/App/SummaryState.swift:12"),
            TranscriptTurns.result(id: "g2", text: "Sources/App/SummaryState.swift:12"),
        ]
        let tally = TranscriptFixture.tally(lines)

        #expect(tally.cold == 2 && tally.withheldOnWorth == 0)
    }

    /// A several-whole-reads answer credits every read it covered, not only the one the pending call was filed under: the identical re-run of the whole line is the escape hatch for both, never a cold miss on the second.
    @Test
    func aSeveralWholeReadsAnswerCreditsEveryReadItCovered() {
        let first = "cat /repo/Sources/App/Depot.swift"
        let second = "cat /repo/Sources/App/Gadget.swift"
        let line = "\(first) && \(second)"
        let answered = InPlaceAnswer.reason(
            calls: ["digest Sources/App/Depot.swift", "digest Sources/App/Gadget.swift"],
            answer: "\(TranscriptFixture.fileDigest("Sources/App/Depot.swift", servedSource: false))\n\n"
                + TranscriptFixture.fileDigest("Sources/App/Gadget.swift", servedSource: false),
            source: 12000,
            standsIn: "",
            wholeCommand: true,
            lookups: 2
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": line], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: answered, isError: true),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": line], turn: "m2", cwd: "/repo"),
        ]

        #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
        #expect(TranscriptFixture.tally(lines).cold == 0)
    }
}

extension TranscriptScanTests {
    /// An `at` digest answers a past revision, never today's working file — so a whole read of that file afterwards is a fresh lookup, not a read scored against a digest that was never made of it.
    @Test
    func aWholeFileReadAfterAnAtDigestIsNotScoredAgainstThatDigest() {
        let lookups = TranscriptFixture.lookups(
            TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "DepotCatalog", "at": "main"]) + [
                TranscriptFixture.toolUse("Read", input: ["file_path": "/repo/DepotCatalog.swift"]),
            ]
        )

        #expect(lookups == [.indexed, .cold(file: "/repo/DepotCatalog.swift", missed: nil)])
    }

    /// Several files answered together on one line each get their own note naming the ranges shown, so the scan credits each as locating its own file rather than crediting every call on the line as though one note, seen at all, spoke for all of them.
    @Test
    func aMultiFileBoundedLineCreditsOnlyTheFilesTheNoteNames() async throws {
        try await TemporaryDirectory.withScope {
            try await Self.multiFileBoundedLineCreditsOnlyTheFilesTheNoteNames()
        }
    }

    private static func multiFileBoundedLineCreditsOnlyTheFilesTheNoteNames(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let root = try MCPTestRepo.make(declaring: "Gamma")
        // Padded well past a bare `let count = N`, so a window of a couple of members outweighs the fixed
        // cost of framing a bounded answer around the compact listing it resolves to.
        let padding = String(repeating: "x", count: 350)
        let members = (1 ... 30).map { "    func part\($0)() -> Int {\n        let count = \($0) // \(padding)\n        return count * 2\n    }" }
        let source = "/// The test type.\nstruct Gamma {\n" + members.joined(separator: "\n") + "\n}\n"
        try source.write(to: root.appendingPathComponent("Sources/App/Gamma.swift"), atomically: true, encoding: .utf8)
        try source.replacingOccurrences(of: "Gamma", with: "Delta")
            .write(to: root.appendingPathComponent("Sources/App/Delta.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root, registry: nil).ensureFresh()

        // One file's own whole digest, measured with room to spare, so the budget below can sit above it
        // while sitting under twice it — each file fits alone, and only together do they not.
        let single = try #require(InPlaceShape.match(forShell: "cat Sources/App/Gamma.swift", in: root.path), sourceLocation: sourceLocation)
        let backoff = try InPlaceBackoff(directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"))
        // On threads of their own: the answerer blocks its caller on work it hands the concurrency pool.
        let first = await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.answer(single, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
        guard case let .answered(oneFile) = first else {
            Issue.record("expected Gamma.swift's own digest to be answered")
            return
        }
        let budget = oneFile.reason.utf8.count + 1000
        // Windows wide enough that each file's whole digest is smaller than its own lines, so only the budget sets the digests aside.
        let command = "sed -n '3,60p' Sources/App/Gamma.swift; sed -n '3,60p' Sources/App/Delta.swift"
        let suppressions = try SuppressionLog(fileURL: TemporaryDirectory.make("suppressions").appendingPathComponent("s.jsonl"))
        let lookup = try #require(PreToolUseCommand.lookup(command: command, payload: [:], in: root.path, noting: suppressions, couldAnswer: { _, _ in true }), sourceLocation: sourceLocation)
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("advice"))
        let usage = try UsageLog(fileURL: TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl"))
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1"],
                cwd: root.path,
                ledger: ledger,
                usage: usage,
                suppressions: suppressions,
                // Tight enough that both files' whole digests together are over budget, though each fits alone.
                answerer: { match, gone, _ in
                    InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: budget, backoff: backoff)
                }
            )
        }
        let json = try #require(outcome.json, sourceLocation: sourceLocation)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        let hookOutput = try #require(payload["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
        let reason = try #require(hookOutput["permissionDecisionReason"] as? String, sourceLocation: sourceLocation)

        // The opening line names both files as their whole digests, with a note naming each one's bounded
        // ranges — where item 1's bug stood, no note at all, so the scan below would have credited both as
        // digested rather than merely located.
        #expect(reason.hasPrefix(
            "sift answered this with `digest Sources/App/Gamma.swift`, `digest Sources/App/Delta.swift` "
                + "(only members of Sources/App/Gamma.swift lines 3-60; Sources/App/Delta.swift lines 3-60 are shown; "
                + "the whole digest is over the size budget) instead of running it"
        ))

        var state = TranscriptScanState()
        let lines = [
            TranscriptTurns.call("Bash", id: "b1", input: ["command": command], turn: "m1", cwd: root.path),
            TranscriptTurns.result(id: "b1", text: reason, isError: true),
        ]
        for line in lines {
            _ = TranscriptScan.events(line: line, state: &state)
        }

        let key = CallerRoot.root(forCallerIn: root.path) ?? ""
        for name in ["Gamma", "Delta"] {
            let file = root.appendingPathComponent("Sources/App/\(name).swift").path
            #expect(state.locates(file, in: key), "\(name)")
            #expect(!state.digestedWhole(file, in: key), "\(name)")
        }
    }
}

// MARK: - A shell window is put to the floor as the ranged Read it stands for

extension TranscriptScanTests {
    /// A window stands for a ranged Read, floor included: below it `digest` serves the source, so the window saved nothing and is no miss — even where a digest located the file first.
    @Test(arguments: [false, true])
    func aWindowOfAFileBelowTheFloorIsNotAMiss(locatedFirst: Bool) {
        let digest = locatedFirst ? TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "CallerRoot"]) : []
        let lookups = TranscriptFixture.lookups(
            digest + [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n '1,45p' Sources/App/CallerRoot.swift"], cwd: "/repo"),
            ],
            belowFloor: { $0 == "/repo/Sources/App/CallerRoot.swift" }
        )

        #expect(lookups == (locatedFirst ? [.indexed] : []) + [.belowFloor(file: "Sources/App/CallerRoot.swift")])
    }

    /// A window whose file cannot be spelled out in full is never put to the floor, which would read the audit's own working directory's file of that name instead.
    @Test
    func aWindowWithNoDirectoryIsNotPutToTheFloor() {
        let lookups = TranscriptFixture.lookups(
            [TranscriptFixture.toolUse("Bash", input: ["command": "sed -n '1,45p' Sources/App/CallerRoot.swift"])],
            belowFloor: { _ in true }
        )

        #expect(lookups == [.cold(file: "Sources/App/CallerRoot.swift", missed: nil)])
    }
}

extension TranscriptScanTests {
    /// A grep of one file whose pattern names nothing a declaration could be is a text search, as the same grep across a tree is: a literal, a quoted fragment of prose, a punctuation regex under a line window.
    @Test
    func aOneFileGrepForAPatternNamingNothingIsATextSearch() {
        let commands = [
            "grep -n \"#127\" Sources/App/View.swift",
            "grep -n \"``.*(.*:.*)``\" Sources/App/View.swift | head -5",
        ]
        for command in commands {
            let lookups = TranscriptFixture.lookups([TranscriptFixture.toolUse("Bash", input: ["command": command])])
            #expect(lookups == [.textSearch(cause: .patternInOneFile)], "\(command)")
        }
        // The same on the `Grep` tool's surface, whose path names the one file.
        let grep = TranscriptFixture.toolUse("Grep", input: ["pattern": "#127", "path": "Sources/App/View.swift", "output_mode": "content"])

        #expect(TranscriptFixture.lookups([grep]) == [.textSearch(cause: .patternInOneFile)])
    }

    /// A grep of one file that names something stays the lookup it was, and so does a column-0 `^}`, which names nothing but is the ends of the file's declarations the hook answers in place from the digest.
    @Test
    func aOneFileGrepThatNamesSomethingOrAsksForClosersIsStillCold() {
        let commands = [
            "grep -n 'SummaryState' Sources/App/View.swift",
            "grep -n 'func SummaryState' Sources/App/View.swift",
            "grep -n '^}' Sources/App/View.swift",
            "grep -n -e '#127' -e SummaryState Sources/App/View.swift",
        ]
        for command in commands {
            let lookups = TranscriptFixture.lookups([TranscriptFixture.toolUse("Bash", input: ["command": command])])
            #expect(lookups == [.cold(file: nil, missed: .digest)], "\(command)")
        }
    }

    /// A pattern that matches every line of the file is the whole read the hook answers in place as `cat -n F` — not a text search out of the denominator — and neither is any inverted search, whatever its pattern.
    @Test
    func aOneFileGrepThatPrintsEveryLineIsStillCold() {
        let commands = [
            "grep -n '^' Sources/App/View.swift",
            "grep -n . Sources/App/View.swift",
            "grep -n '$' Sources/App/View.swift",
            "grep -vn '^$' Sources/App/View.swift",
            "grep -n '^' Sources/App/View.swift | head -80",
        ]
        for command in commands {
            let lookups = TranscriptFixture.lookups([TranscriptFixture.toolUse("Bash", input: ["command": command])])
            #expect(lookups == [.cold(file: nil, missed: .digest)], "\(command)")
        }
        // The same on the `Grep` tool's surface, whose pattern matches every line.
        let grep = TranscriptFixture.toolUse("Grep", input: ["pattern": ".", "path": "Sources/App/View.swift", "output_mode": "content"])

        #expect(TranscriptFixture.lookups([grep]) == [.cold(file: nil, missed: .digest)])
    }

    /// The bug this closes: an empty pattern was read as a stray "bare number" flag value and skipped, which left the file that followed it misread as the pattern and no path behind the search at all — so `readsSwift` found no `.swift` file named and the scan never counted the command as a lookup.
    ///
    /// It is one now, cold unless located, the same whole read `cat F.swift` is.
    @Test
    func anEmptyPatternGrepIsStillCounted() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", input: ["command": "grep -n \"\" Sources/App/View.swift"]),
        ])

        #expect(lookups == [.cold(file: nil, missed: .digest)])
    }

    /// A reading's spaced name only matches the run its words are actually written as: `My/A.swift` spells `A.swift`, not `My A.swift`, even though both of that name's words appear somewhere on the line.
    @Test
    func aSpacedReadingOnlyMatchesItsWordsAsAConsecutiveRun() {
        let spaced = ServedReading(keys: ["spaced"], names: ["My A.swift"])
        let plain = ServedReading(keys: ["plain"], names: ["A.swift"])

        let served = ServedReading.keys(servedBy: ["digest Sources/My/A.swift"], note: nil, among: [spaced, plain])

        #expect(served == ["plain"])
    }
}
