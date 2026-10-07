//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup the advice hook answered in a refusal's place is the index serving it, on every surface that counts lookups — the scan and its tally, `audit`, the status line and `usage` — and never a refusal routed around, and never cold.
///
/// Every line here is shaped as the harness writes it (``TranscriptTurns``): a result carries its call's id, its content and the error flag, and nothing naming the tool.
@Suite(.temporaryDirectories)
struct InPlaceAccountingTests {
    private static var file: String {
        "/repo/Sources/App/Depot.swift"
    }

    private static var grep: String {
        #"grep -n 'static\|case ' /repo/Sources/App/Depot.swift"#
    }

    /// The refusal the hook writes when it answers a digest in place, as the result of the call it answered.
    private static var answered: String {
        InPlaceAnswer.reason(
            calls: ["digest Sources/App/Depot.swift"],
            answer: TranscriptFixture.fileDigest("Sources/App/Depot.swift", servedSource: false),
            source: 12000,
            standsIn: ""
        ).text
    }

    /// A Bash lookup the hook answered, as the two lines a transcript holds it in.
    private static func answeredGrep(id: String = "c1", turn: String = "m1") -> [Data] {
        [
            TranscriptTurns.call("Bash", id: id, input: ["command": grep], turn: turn, cwd: "/repo"),
            TranscriptTurns.result(id: id, text: answered, isError: true),
        ]
    }

    /// The lookup is taken back from the bucket it was counted in and counted as indexed — never a refusal, and never cold.
    @Test
    func anAnsweredRefusalIsTheIndexServingTheLookup() {
        let tally = TranscriptFixture.tally(Self.answeredGrep())

        #expect(tally.indexed == 1)
        #expect(tally.answered == 1)
        #expect(tally.cold == 0)
        #expect(tally.refusals == 0)
        #expect(tally.textSearches == 0)
        #expect(tally.shareText == "100%")
    }

    /// What the answer located is credited as an index call's answer is: a ranged read of the file afterwards is guided, and a whole read of it — asked some other way than the answered command — is read whole after its digest.
    @Test
    func anAnswerLocatesTheFileItDigested() {
        let answeredRead = [
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": Self.file], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "r1", text: Self.answered, isError: true),
        ]
        let ranged = TranscriptTurns.call("Read", id: "r2", input: ["file_path": Self.file, "offset": 10, "limit": 20], turn: "m2")
        let whole = TranscriptTurns.call("Read", id: "r3", input: ["file_path": Self.file], turn: "m2")

        let guided = TranscriptFixture.tally(answeredRead + [ranged])
        let readWhole = TranscriptFixture.tally(Self.answeredGrep() + [whole])

        #expect(guided.indexed == 1 && guided.guided == 1 && guided.cold == 0)
        #expect(readWhole.indexed == 1 && readWhole.readWholeAfterDigest == 1 && readWhole.cold == 0)
    }

    /// The identical re-run an answer offers is never held against the context, in either spelling: the answer named the re-run as its way to the raw output, so a `cat` and a `Read` of the file it answered both score out of the share.
    @Test
    func theReRunAnAnswerOffersIsNeverHeldAgainstTheContext() {
        let cat = "cat /repo/Sources/App/Depot.swift"
        let answeredCat = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": cat], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: Self.answered, isError: true),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": cat], turn: "m2", cwd: "/repo"),
        ]
        let answeredRead = [
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": Self.file], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "r1", text: Self.answered, isError: true),
            TranscriptTurns.call("Read", id: "r2", input: ["file_path": Self.file], turn: "m2", cwd: "/repo"),
        ]
        let answeredGrepRerun = Self.answeredGrep() + [TranscriptTurns.call("Bash", id: "c2", input: ["command": Self.grep], turn: "m2", cwd: "/repo")]

        for lines in [answeredCat, answeredRead, answeredGrepRerun] {
            let tally = TranscriptFixture.tally(lines)
            // Withheld on worth: the hook answered this lookup from the index a moment earlier, so the
            // half that says the index never recorded it is the one thing the re-run cannot be.
            #expect(TranscriptFixture.lookups(lines).last == .withheldOnWorth(rule: .retryAllowed))
            #expect(tally.readWholeAfterDigest == 0 && tally.cold == 0)
            #expect(tally.indexed == 1 && tally.withheldOnWorth == 1)
        }
    }

    /// An answer made of several calls credits each of them, the last as much as the first: a whole read of the file the second call digested is read whole after its digest.
    @Test
    func everyCallAnAnswerNamesIsCredited() {
        let several = InPlaceAnswer.reason(
            calls: ["digest Screen", "digest Row"],
            answer: "tree: App\nScreen — App — Sources/App/Screen.swift:2-40\n\nRow — App — Sources/App/Row.swift:2-40",
            source: nil,
            standsIn: "a member's source is served as it stands"
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "grep -n 'var body' /repo/Sources/App/Screens.swift"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: several, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Row.swift"], turn: "m2"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1 && tally.answered == 1 && tally.readWholeAfterDigest == 1)
    }

    /// A shared answer's floor verdict is credited for each file it carries, not the top file's alone: the second file's own header, past the first, decides the second file's floor — read whole afterwards, it is below the floor it served source for rather than read whole after a digest that never weighed it.
    ///
    /// Runs the real join: `InPlaceAnswerer.computeParts` (through `InPlaceAnswerer.answer`) over an above-floor `Depot.swift` and a below-floor `Alpha.swift`, so the boundary the test reads back is the one production actually writes, not one hand-placed in a fixture. A `printf` that leaves its line unfinished, at the top of the line or between the reads, still leaves the file after it a header the audit reads.
    @Test(arguments: [
        "cat Sources/App/Depot.swift; cat Sources/App/Alpha.swift",
        "printf 'x'; cat Sources/App/Alpha.swift; cat Sources/App/Depot.swift",
        "cat Sources/App/Depot.swift; printf 'x'; cat Sources/App/Alpha.swift",
    ])
    func aSharedAnswersSecondFileCreditsItsOwnFloorVerdict(command: String) async throws {
        // A declared package, unlike `InPlaceAnswerTests.indexedRepository()`, so neither file's digest
        // carries a "module guessed" warning ahead of its header — noise this test has no stake in.
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let members = (1 ... 40).map { index in
            "    func stock\(index)() -> Int {\n        let count = \(index)\n        let doubled = count * 2\n        return doubled + count\n    }"
        }
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "/// A depot.\nstruct Depot {\n" + members.joined(separator: "\n") + "\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": command], turn: "m1", cwd: root.path),
            TranscriptTurns.result(id: "c1", text: answered.reason, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": root.appendingPathComponent("Sources/App/Alpha.swift").path], turn: "m2"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1 && tally.belowFloor == 1 && tally.readWholeAfterDigest == 0)
    }

    /// A refusal that carries several whole reads' answers under one opening line credits every one of them, not just the first: a whole read of either file afterwards is read whole after its digest.
    @Test
    func aMultiCallOpeningLineCreditsEveryCallItNames() {
        let several = InPlaceAnswer.reason(
            calls: ["digest Sources/App/Depot.swift", "digest Sources/App/Gizmo.swift"],
            answer: "Sources/App/Depot.swift — module: App\nimports: Foundation\n\npublic struct Depot — 1 member  :1-3"
                + "\n\nSources/App/Gizmo.swift — module: App\nimports: Foundation\n\npublic struct Gizmo — 1 member  :1-3",
            source: nil,
            standsIn: "these answers did not weigh themselves against their sources"
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "cat /repo/Sources/App/Depot.swift; cat /repo/Sources/App/Gizmo.swift"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: several, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Depot.swift"], turn: "m2"),
            TranscriptTurns.call("Read", id: "r2", input: ["file_path": "/repo/Sources/App/Gizmo.swift"], turn: "m3"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1 && tally.readWholeAfterDigest == 2 && tally.cold == 0)
    }

    /// A target quoted in its call — a path holding a space — is stripped of its quotes before it is credited, exactly as a whole read of that same path is: a probe naming a document by its quoted target and one naming it by its bare path are the one file.
    @Test
    func aQuotedTargetIsCreditedUnquoted() {
        let answered = InPlaceAnswer.reason(
            calls: ["digest 'Sources/My App/Depot.swift'"],
            answer: "Sources/My App/Depot.swift — module: App\nimports: Foundation\n\npublic struct Depot — 1 member  :1-3",
            source: nil,
            standsIn: "this digest did not weigh itself against the file's source"
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "cat '/repo/Sources/My App/Depot.swift'"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: answered, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/My App/Depot.swift"], turn: "m2"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1 && tally.readWholeAfterDigest == 1 && tally.cold == 0)
    }

    /// An answered sweep credits the name it was asked about, in either spelling of its call — the tool's `(refs: true)` or the CLI's `--refs` — so a ranged read of the file declaring it is guided.
    @Test(arguments: ["where Gadget (refs: true)", "sift where Gadget --refs"])
    func anAnsweredSweepLocatesTheNameItWasAskedAbout(call: String) {
        let sweep = InPlaceAnswer.reason(calls: [call], answer: "tree: App\nwhere Gadget", source: nil, standsIn: "a `where` answer stands in for a search's output").text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "grep -rnw --include=*.swift Gadget /repo/Sources"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: sweep, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Gadget.swift", "offset": 1, "limit": 20], turn: "m2"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.answered == 1)
        #expect(tally.guided == 1)
        #expect(tally.cold == 0)
    }

    /// A `Grep` answered in place is counted exactly as a Bash lookup is — the index serving the search — and credits the `where` call it was answered with, so a ranged read of the file declaring the name is guided.
    @Test
    func anAnsweredGrepIsTheIndexServingTheSearch() {
        let input: [String: Any] = ["output_mode": "content", "pattern": "Gadget", "path": "/repo/Sources", "type": "swift"]
        let answer = InPlaceAnswer.reason(
            calls: ["where Gadget"],
            answer: "tree: App\nwhere Gadget\n\ndeclarations (1):\n  App.Gadget — struct — Sources/App/Gadget.swift:1-3",
            source: nil,
            standsIn: "a `where` answer stands in for a search's output, which was never produced"
        ).text
        let lines = [
            TranscriptTurns.call("Grep", id: "g1", input: input, turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "g1", text: answer, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Gadget.swift", "offset": 1, "limit": 20], turn: "m2"),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1)
        #expect(tally.answered == 1)
        #expect(tally.guided == 1)
        #expect(tally.cold == 0)
        #expect(tally.refusals == 0)
        // The identical re-run the answer offered is the same escape hatch a Bash lookup's is.
        let reRun = TranscriptFixture.tally(lines + [TranscriptTurns.call("Grep", id: "g2", input: input, turn: "m3", cwd: "/repo")])
        #expect(reRun.withheldOnWorth == 1 && reRun.cold == 0)
    }

    /// The `Grep` input an alternation of a declared name and unrecorded prose is answered for, and where it goes on to be re-run identically.
    private static var partialGrepInput: [String: Any] {
        ["output_mode": "content", "pattern": "Depot|stale index", "path": "/repo/Sources", "type": "swift"]
    }

    /// The refusal the hook writes for `partialGrepInput`: `where Depot`, with the caveat naming the prose it leaves for the identical re-run.
    private static var partiallyAnswered: String {
        let caveat = InPlaceAnswer.caveat(uncovered: ["stale index"]) ?? ""
        return InPlaceAnswer.reason(
            calls: ["where Depot"],
            answer: "tree: App\nwhere Depot\n\n\(caveat)\n\ndeclarations (1):\n  App.Depot — struct — Sources/App/Depot.swift:1-3",
            source: nil,
            standsIn: "a `where` answer stands in for a search's output, which was never produced"
        ).text
    }

    /// `partialGrepInput`, answered, as the two lines a transcript holds it in.
    private static func partiallyAnsweredGrep(id: String = "p1", turn: String = "m1") -> [Data] {
        [
            TranscriptTurns.call("Grep", id: id, input: partialGrepInput, turn: turn, cwd: "/repo"),
            TranscriptTurns.result(id: id, text: partiallyAnswered, isError: true),
        ]
    }

    /// A partial in-place answer's caveat is its own count, apart from every other answer, and the identical re-run it promises is credited as the sweep it is.
    @Test
    func aPartialAnswerFollowedByItsSweepCountsBoth() {
        let sweep = TranscriptTurns.call("Grep", id: "p2", input: Self.partialGrepInput, turn: "m2", cwd: "/repo")
        let tally = TranscriptFixture.tally(Self.partiallyAnsweredGrep() + [sweep])

        #expect(tally.answered == 1)
        #expect(tally.partialAnswers == 1)
        #expect(tally.partialAnswersSwept == 1)
        // The sweep is the sanctioned escape hatch, never a cold lookup or a text search.
        #expect(tally.withheldOnWorth == 1 && tally.cold == 0 && tally.textSearches == 0)
    }

    /// A partial answer with no re-run behind it counts as an answer still waiting on its sweep.
    @Test
    func aPartialAnswerWithNoSweepIsNotCountedSwept() {
        let tally = TranscriptFixture.tally(Self.partiallyAnsweredGrep())

        #expect(tally.partialAnswers == 1)
        #expect(tally.partialAnswersSwept == 0)
    }

    /// An in-place answer with nothing left uncovered carries no caveat, and so no partial answer.
    @Test
    func aPlainInPlaceAnswerCarriesNoPartialAnswer() {
        let tally = TranscriptFixture.tally(Self.answeredGrep())

        #expect(tally.partialAnswers == 0)
        #expect(tally.partialAnswersSwept == 0)
    }

    /// `audit` prints the partial-answer row only where one fired, beside `answered`, and says whether the sweep followed.
    @Test
    func theAuditPrintsThePartialAnswerRowOnlyWhenThereIsOne() throws {
        let sweep = TranscriptTurns.call("Grep", id: "p2", input: Self.partialGrepInput, turn: "m2", cwd: "/repo")
        let root = try Self.projects(Self.partiallyAnsweredGrep() + [sweep])
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("partial answers     1  followed by the sweep re-run     1"))

        let plainRoot = try Self.projects(Self.answeredGrep())
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        let plainReport = TranscriptAudit.render(projectsDirectory: plainRoot)

        #expect(!plainReport.contains("partial answers"))
    }

    /// An answer costs no round trip — the turn after it acts on the answer — so it is never priced as a refusal's.
    @Test
    func anAnswerIsNeverChargedARoundTrip() {
        let next = TranscriptTurns.Usage(input: 3, cacheRead: 500_000, cacheCreation: 1000)
        let tally = TranscriptFixture.tally(Self.answeredGrep() + [TranscriptTurns.text("Reading the digest.", turn: "m2", usage: next)])

        #expect(tally.soloRefusals == 0)
        #expect(tally.resentTokens == 0)
    }

    /// `audit` counts it under `indexed` and says how many the hook answered, and lists no miss for it.
    @Test
    func theAuditCountsItAsIndexed() throws {
        let root = try Self.projects(Self.answeredGrep())
        defer { try? FileManager.default.removeItem(at: root) }

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("served by sift — 100% of the lookups that had a choice"))
        #expect(report.contains("answered     1  of those, by the advice hook in a refusal's place"))
        #expect(!report.contains("cold lookups, worst first"))
    }

    /// The scan counts it in the share, though the hook priced a saving for it on the usage log under this session.
    @Test
    func theScanCountsItInTheShareWhateverTheUsageLogPriced() throws {
        let directory = try TemporaryDirectory.make("inplace-status")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("session.jsonl")
        try Data(Self.answeredGrep().flatMap { $0 + [0x0A] }).write(to: transcript)
        let usageLog = directory.appendingPathComponent("usage.jsonl")
        UsageLog(fileURL: usageLog).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 3000, source: 23000), session: "session", via: "hook"
        )

        let tally = TranscriptFixture.scored(transcript: transcript)

        #expect(tally.shareText == "100%")
        #expect(tally.total == 1)
    }

    /// `usage` reads the hook's line as the call it was, with its saving: a digest that stood in for its source.
    @Test
    func usageCountsItAsACallWithItsSaving() throws {
        let log = try TemporaryDirectory.make("inplace-usage").appendingPathComponent("inplace-usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        UsageLog(fileURL: log).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 3000, source: 23000), agent: "a1", session: "s1", via: "hook"
        )

        let scan = try UsageScan.load(fileURL: log).get()

        #expect(scan.entries.map(\.tool) == ["digest"])
        #expect(scan.entries.first?.session == "s1")
        #expect(scan.entries.first?.agent == "a1")
        #expect(scan.savings?.total.saved == 20000)
    }

    /// The `usage` report labels the in-place answers' part of its saving as gross, and names the audit as where those reads are counted.
    @Test
    func usageLabelsTheInPlaceSavingGross() throws {
        let log = try TemporaryDirectory.make("inplace-usage").appendingPathComponent("inplace-gross.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        UsageLog(fileURL: log).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 3000, source: 23000), session: "s1", via: "hook"
        )

        let report = UsageReport.render(fileURL: log)

        #expect(report.contains("     1  answered in place by the advice hook: ~5.0k tokens of that estimate — "
                + "this and the figure above are gross: a digest or answer whose file was then read whole anyway still counts, "
                + "which this log cannot see; sift audit counts those reads"))
    }

    /// A compound line's answer is remembered under exactly the lookups it served, as the hook's ledger records it: the name grep it dropped is not among them, and the read after the first is.
    @Test
    func aCompoundAnswerIsRememberedUnderTheLookupsItServed() {
        let grep = "grep -rn Depot /repo/Sources/App/Beta.swift /repo/Tests"
        let line = "\(grep); cat /repo/Sources/App/A.swift; cat /repo/Sources/App/G.swift"
        let two = InPlaceAnswer.reason(
            calls: ["digest Sources/App/A.swift", "digest Sources/App/G.swift"],
            answer: "Sources/App/A.swift — module: App\n\npublic struct A — 1 member  :1-3"
                + "\n\nSources/App/G.swift — module: App\n\npublic struct G — 1 member  :1-3",
            source: nil,
            standsIn: "these answers did not weigh themselves against their sources"
        ).text
        let answered = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": line], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: two, isError: true),
        ]
        let rerunOfTheSecondRead = answered + [
            TranscriptTurns.call("Bash", id: "c2", input: ["command": "cat /repo/Sources/App/G.swift"], turn: "m2", cwd: "/repo"),
        ]
        let droppedGrep = answered + [TranscriptTurns.call("Bash", id: "c2", input: ["command": grep], turn: "m2", cwd: "/repo")]

        #expect(TranscriptFixture.lookups(rerunOfTheSecondRead).last == .withheldOnWorth(rule: .retryAllowed))
        #expect(TranscriptFixture.lookups(droppedGrep).last != .withheldOnWorth(rule: .retryAllowed))

        // Answered as the whole line, the grep is served too, and its re-run is the identical re-run of an answer.
        let three = InPlaceAnswer.reason(
            calls: ["where Depot", "digest Sources/App/A.swift", "digest Sources/App/G.swift"],
            answer: "tree: App\nwhere Depot",
            source: nil,
            standsIn: "these answers did not weigh themselves against their sources"
        ).text
        let servedGrep = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": line], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "c1", text: three, isError: true),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": grep], turn: "m2", cwd: "/repo"),
        ]
        #expect(TranscriptFixture.lookups(servedGrep).last == .withheldOnWorth(rule: .retryAllowed))
    }

    /// An answer whose opening line spells no reading of its line is remembered under none of the line's lookups, rather than under the first reading's; a quoted path holding a space is still spelled by its call.
    @Test
    func aCompoundAnswerNoReadingSpellsIsRememberedUnderNone() {
        let answered = { (line: String, calls: [String]) in
            [
                TranscriptTurns.call("Bash", id: "c1", input: ["command": line], turn: "m1", cwd: "/repo"),
                TranscriptTurns.result(id: "c1", text: InPlaceAnswer.reason(
                    calls: calls,
                    answer: "tree: App",
                    source: nil,
                    standsIn: "these answers did not weigh themselves against their sources"
                ).text, isError: true),
                TranscriptTurns.call("Bash", id: "c2", input: ["command": "cat /repo/Sources/App/G.swift"], turn: "m2", cwd: "/repo"),
            ]
        }
        let unspelled = answered(
            "cat /repo/Sources/App/A.swift; cat /repo/Sources/App/G.swift",
            ["digest Sources/App/Z.swift", "digest Sources/App/Q.swift"]
        )
        let quoted = answered(
            "cat '/repo/Sources/App/My A.swift'; cat /repo/Sources/App/G.swift",
            ["digest 'Sources/App/My A.swift'", "digest Sources/App/G.swift"]
        )

        #expect(TranscriptFixture.lookups(unspelled).last != .withheldOnWorth(rule: .retryAllowed))
        #expect(TranscriptFixture.lookups(quoted).last == .withheldOnWorth(rule: .retryAllowed))
    }

    /// A whole read of a file in a checkout since removed, answered in place from the live repository with no change of directory, locates that file, spelled from the path the line named rather than the directory it ran in.
    @Test
    func anInPlaceAnswerToAGoneCheckoutsFileByItsFullPathLocatesIt() throws {
        let here = try MCPTestRepo.make()
        let file = here.appendingPathComponent(".claude/worktrees/agent-gone/Sources/App/Depot.swift").path
        let answer = InPlaceAnswer.reason(
            calls: ["digest Sources/App/Depot.swift"],
            answer: TranscriptFixture.fileDigest("Sources/App/Depot.swift", servedSource: false, tree: "repo (worktree agent-gone)"),
            source: nil,
            standsIn: ""
        ).text
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "cat \(file)"], turn: "m1", cwd: here.path),
            TranscriptTurns.result(id: "c1", text: answer, isError: true),
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": file], turn: "m2", cwd: here.path),
        ]

        let tally = TranscriptFixture.tally(lines)

        #expect(tally.indexed == 1 && tally.readWholeAfterDigest == 1 && tally.cold == 0)
    }

    /// A `projects/<project>/<session>.jsonl` tree holding `lines`, for the audit to sweep.
    private static func projects(_ lines: [Data]) throws -> URL {
        let root = try TemporaryDirectory.make("inplace-audit").appendingPathComponent("inplace-audit")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: directory.appendingPathComponent("11112222-3333.jsonl"))
        return root
    }
}
