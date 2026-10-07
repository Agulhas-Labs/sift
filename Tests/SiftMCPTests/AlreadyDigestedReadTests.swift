//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a file this context has already been served the digest of goes through: the context has seen the summary, and asks for source only because the summary was not enough.
@Suite(.temporaryDirectories)
struct AlreadyDigestedReadTests {
    /// The measured case: a subagent runs `sift digest Shell` from Bash, then `cat -n` of the file the type is named for.
    @Test func aCatAfterABashDigestOfTheFilesTypeIsLetThrough() async throws {
        let fixture = try Fixture()
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"])
        let verdict = try fixture.verdict(fixture.shellRead("cat -n Sources/App/Shell.swift"))

        #expect(verdict.line == "allowed\t\talreadyDigested")
    }

    /// A digest asked for by path through the MCP tool lets a whole `Read` of that path through.
    @Test func aReadAfterAnMCPDigestOfThePathIsLetThrough() throws {
        let fixture = try Fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let verdict = fixture.verdict(fixture.wholeRead())

        #expect(verdict.line == "allowed\t\talreadyDigested")
    }

    /// A Bash `sift digest --at <rev>` answers a past revision, never today's file — `cliDigests` leaves the whole call out of the ledger, so a later whole read of the file is still answered rather than let through as digested.
    @Test func aCatAfterABashDigestAtARevisionIsStillAnswered() async throws {
        let fixture = try Fixture()
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest --at HEAD Shell"])
        let verdict = try fixture.verdict(fixture.shellRead("cat -n Sources/App/Shell.swift"))

        #expect(verdict.token == "in-place")
    }

    /// The MCP form of the same call — `digest target: ... at: <rev>` — is left out of the ledger too, so a whole `Read` of the path afterwards is still answered.
    @Test func aReadAfterAnMCPDigestAtARevisionIsStillAnswered() throws {
        let fixture = try Fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift", "at": "HEAD"])
        let verdict = fixture.verdict(fixture.wholeRead())

        #expect(verdict.token == "in-place")
    }

    /// A digest the hook itself answered in place counts too, so a whole `Read` after an answered `cat` is let through.
    @Test func aReadAfterAnInPlaceDigestIsLetThrough() throws {
        let fixture = try Fixture()
        let first = try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift"))
        #expect(first.token == "in-place")
        let verdict = fixture.verdict(fixture.wholeRead())
        #expect(verdict.line == "allowed\t\talreadyDigested")
    }

    /// The digest of another file says nothing about this one, so its read is still answered.
    @Test func aDigestOfAnotherFileLeavesTheReadAnswered() throws {
        let fixture = try Fixture()
        fixture.take(tool: "Bash", input: ["command": "sift digest Other Sources/App/Other.swift"])
        let verdict = try fixture.verdict(fixture.shellRead("cat -n Sources/App/Shell.swift"))

        #expect(verdict.token == "in-place")
    }

    /// Another session never saw this one's digest, so its read is still answered.
    @Test func aDigestInAnotherSessionLeavesTheReadAnswered() throws {
        let fixture = try Fixture()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"])
        let verdict = fixture.verdict(fixture.wholeRead(), session: "s2")

        #expect(verdict.token == "in-place")
    }

    /// A window of a file nothing in this context has located is the lookup itself, answered in place with the file's digest as a whole read is, in either spelling.
    @Test func aColdWindowIsAnsweredInPlaceWithTheFilesDigest() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let window = try fixture.classified(command: "sed -n '1,30p' Sources/App/Shell.swift")
        let ranged = try fixture.classified(rangedReadFrom: 1)

        #expect(window.inPlace?.calls.map(\.readPath) == ["Sources/App/Shell.swift"])
        #expect(ranged.inPlace?.calls.map(\.readPath) == [fixture.file])
        #expect(fixture.verdict(window, session: "s2").token == "in-place")
        #expect(fixture.verdict(ranged, session: "s3").token == "in-place")
    }

    /// Once the context has been handed the file's digest, a window of it is no lookup at all — let through with nothing noted, where a whole read of the same file is logged `alreadyDigested`.
    @Test func aWindowOfADigestedFileIsNoLookup() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])

        #expect(try fixture.verdict(fixture.classified(command: "sed -n '1,30p' Sources/App/Shell.swift")).line == "allowed\t\tnoLookup")
        #expect(try fixture.verdict(fixture.classified(command: "cat Sources/App/Shell.swift | head -30")).line == "allowed\t\tnoLookup")
        #expect(try fixture.verdict(fixture.classified(rangedReadFrom: 1)).line == "allowed\t\tnoLookup")
        #expect(!FileManager.default.fileExists(atPath: fixture.stores.appendingPathComponent("suppressions.jsonl").path))
    }

    /// On a line of windows over two files, the windows of the file this context has located are dropped: the other file's read alone is handed to the answerer, marked as leaving the dropped windows to print, so the line runs with the note naming its call (`HeldWindowLineTests`), and a line of the located file's windows alone is no lookup.
    @Test func aLocatedFilesWindowsLeaveTheOtherFilesDigest() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        try fixture.lengthen("Other")
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let mixed = try fixture.classified(command: "sed -n '1,30p' Sources/App/Shell.swift; sed -n '5,40p' Sources/App/Other.swift")
        let located = try fixture.classified(command: "sed -n '1,30p' Sources/App/Shell.swift && sed -n '40,60p' Sources/App/Shell.swift")

        #expect(fixture.handed(mixed)?.map(\.readPath) == ["Sources/App/Other.swift"])
        #expect(fixture.verdict(located).line == "allowed\t\tnoLookup")
    }

    /// The identical re-run of a line of several windows of one file is allowed, every window on it having been answered by the one digest — which located the file, so the re-run is a line of a located file's windows and no lookup.
    @Test func aRerunOfSeveralWindowsOfOneFileIsAllowed() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let command = "sed -n '1,30p' Sources/App/Shell.swift; sed -n '40,60p' Sources/App/Shell.swift; sed -n '80,90p' Sources/App/Shell.swift"

        #expect(try fixture.verdict(fixture.classified(command: command, rerunIn: "s2"), session: "s2").token == "in-place")
        #expect(try fixture.verdict(fixture.classified(command: command, rerunIn: "s2"), session: "s2").line == "allowed\t\tnoLookup")
    }

    /// A search of a digested file is a question the digest did not answer, and a ranged read is no lookup at all: both are as they were.
    @Test func aSearchOrARangedReadAfterADigestIsUnchanged() throws {
        let fixture = try Fixture()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"])
        let search = try fixture.verdict(fixture.shellRead("grep -n 'func go' Sources/App/Shell.swift"))
        #expect(search.token == "in-place")
        let ranged = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": fixture.file, "offset": 1, "limit": 3]],
            in: fixture.repo.path,
            noting: SuppressionLog(fileURL: fixture.stores.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        )
        #expect(ranged == nil)
    }

    /// Each `sift digest` in a command is read as the CLI reads it: flags and their values are not targets, and `--root` is kept.
    @Test func aBashDigestIsReadAsTheCLIReadsIt() {
        let asked = IndexCallTarget.cliDigests(inCommand: "sift digest --root /r A --offset 3 B --all | head -5; sift where C")

        #expect(asked.map(\.target) == ["A", "B"])
        #expect(asked.map(\.root) == ["/r", "/r"])
    }

    @Test func aRedirectedBashDigestCreditsOnlyTheWordsBeforeIt() {
        let asked = IndexCallTarget.cliDigests(inCommand: "sift digest Zed > /tmp/Engine.txt")

        #expect(asked.map(\.target) == ["Zed"])
    }

    /// A stem alone is not identity: another file of the same name is not this one's digest, even though its last component still spells `Shell`.
    @Test func aReadOfAnotherFileOfTheSameStemIsNotExcused() async throws {
        let fixture = try Fixture()
        try MCPTestRepo.add(["Sources/Other/Shell.swift": "struct Widget {\n    let two = 2\n}\n"], to: fixture.repo)
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"])
        let verdict = try fixture.verdict(fixture.shellRead("cat Sources/Other/Shell.swift"))

        #expect(verdict.token == "in-place")
    }

    /// A nested type's last component can match another file's stem without that file being its digest: `Shell.Inner` declares in `Shell.swift`, not in a file merely named `Inner.swift`.
    @Test func aNestedTypesLastComponentMatchingAnotherFilesStemIsNotExcused() async throws {
        let fixture = try Fixture()
        try MCPTestRepo.add([
            "Sources/App/Shell.swift": "struct Shell {\n    struct Inner {}\n    let one = 1\n    func go() {}\n}\n",
            "Sources/App/Inner.swift": "struct Inner2 {}\n",
        ], to: fixture.repo)
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell.Inner"])
        let verdict = try fixture.verdict(fixture.shellRead("cat Sources/App/Inner.swift"))

        #expect(verdict.token == "in-place")
    }

    /// A digest in a subagent's own context excuses that context's read, but neither the parent session's read nor a sibling subagent's.
    @Test func aDigestInOneAgentDoesNotExcuseAnotherContext() async throws {
        let fixture = try Fixture()
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"], agent: "a1")

        #expect(try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift"), agent: nil).token == "in-place")
        #expect(try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift"), agent: "a2").token == "in-place")
        #expect(try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift"), agent: "a1").line == "allowed\t\talreadyDigested")
    }

    /// Two whole reads in one command are let through only where both are covered: one file digested, the other not, still answers in place.
    @Test func aPartialCompoundReadIsStillAnswered() async throws {
        let fixture = try Fixture()
        try MCPTestRepo.add(["Sources/App/Other.swift": "struct Other {\n    let two = 2\n}\n"], to: fixture.repo)
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell"])
        let verdict = try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift && cat Sources/App/Other.swift"))

        #expect(verdict.token == "in-place")
    }

    /// A digest of some of the file's lines locates it for a window, but is not the file's whole digest: a whole read after it is still answered in place, never let through as already digested.
    @Test func aReadAfterADigestOfSomeLinesIsStillAnswered() throws {
        let fixture = try Fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift:30"])
        let verdict = fixture.verdict(fixture.wholeRead())

        #expect(verdict.token == "in-place")
    }

    /// A bounded window answer is displayed as the file's whole digest, but the ledger keeps the real, line-ranged target it was answered with — so a whole read straight after is still the lookup itself, answered in place, never let through as already digested.
    @Test func aWholeReadAfterABoundedWindowAnswerIsStillAnsweredInPlace() async throws {
        let fixture = try Fixture()
        // One long member, so a window across the end of its body and into the next member outweighs the
        // compact listing it resolves to (item 4) — a window wholly inside one member runs, its answer naming
        // only that member — beside forty short ones, so the whole digest is well over a budget that still fits
        // the bounded one.
        // Padded well past a bare `let aN = N`, so eight of these lines still outweigh the fixed cost of
        // framing a bounded answer around the compact listing they resolve to — the opening line, freshness
        // header and closing line every such answer carries beside its member text — with that closing line
        // claiming its saving, since one that could only deny it is withheld as no smaller than the window, and
        // saving more than the floor a members answer that does not show the window's lines is held to.
        let long = (1 ... 12).map { "        let a\($0) = \($0) // padding-\(String(repeating: "x", count: 600))" }.joined(separator: "\n")
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        let source = "/// The test type.\nstruct Shell {\n    func long() -> Int {\n\(long)\n        return a1\n    }\n"
            + members.joined(separator: "\n") + "\n}\n"
        try source.write(to: fixture.repo.appendingPathComponent("Sources/App/Shell.swift"), atomically: true, encoding: .utf8)
        try await fixture.index()
        let window = try fixture.shellRead("sed -n '8,19p' Sources/App/Shell.swift")
        let (context, cwd, ledger, suppressions) = (fixture.context("s1"), fixture.repo.path, fixture.ledger, fixture.suppressions)
        let usage = UsageLog(fileURL: fixture.stores.appendingPathComponent("usage.jsonl"))
        let backoff = try InPlaceAnswerTests.backoff()
        // On a thread of its own: the answerer blocks its caller on work it hands the concurrency pool.
        let bounded = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: window,
                session: "s1",
                context: context,
                payload: ["agent_id": "a1"],
                cwd: cwd,
                ledger: ledger,
                usage: usage,
                suppressions: suppressions,
                answerer: { match, gone, _ in
                    InPlaceAnswerer.answer(match, serverGone: gone, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: 900, backoff: backoff)
                }
            )
        }

        #expect(bounded.verdict.token == "in-place")

        #expect(fixture.verdict(fixture.wholeRead()).token == "in-place")
    }

    /// A different repository's index never stands in for this one's: a digest of a same-named type elsewhere excuses nothing here.
    @Test func aDifferentRepositoryDoesNotExcuseTheRead() async throws {
        let fixture = try Fixture()
        let elsewhere = try MCPTestRepo.make(declaring: "Shell")
        try await SiftEngine(directory: elsewhere, registry: nil).ensureFresh()
        try await fixture.index()
        fixture.take(tool: "Bash", input: ["command": "sift digest Shell --root \(elsewhere.path)"])
        let verdict = try fixture.verdict(fixture.shellRead("cat Sources/App/Shell.swift"))

        #expect(verdict.token == "in-place")
    }

    /// A window of a located file is no lookup in a shell shape no answer covers too — a subshell, an environment assignment, output sent to `/dev/null` — let through with nothing noted rather than logged `notAnswerable`.
    @Test(arguments: [
        "(sed -n '1,30p' Sources/App/Shell.swift)",
        "LC_ALL=C sed -n '1,30p' Sources/App/Shell.swift",
        "sed -n '1,30p' Sources/App/Shell.swift > /dev/null",
        "(sed -n '1,30p' Sources/App/Shell.swift; sed -n '40,60p' Sources/App/Shell.swift)",
    ])
    func aLocatedFilesWindowInAnUnanswerableShapeIsNoLookup(command: String) throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])

        #expect(try fixture.verdict(fixture.classified(command: command)).line == "allowed\t\tnoLookup")
        #expect(!FileManager.default.fileExists(atPath: fixture.stores.appendingPathComponent("suppressions.jsonl").path))
    }

    /// A window behind literal `cd`s — relative, one after another, or absolute — is judged as the same window without them: cold, it is answered in place with its file's digest; located, it is no lookup, in an answered shape or in one no answer covers.
    @Test func aWindowBehindLiteralCdsIsJudgedAsTheSameWindowWithoutThem() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let commands = [
            "cd Sources/App && sed -n '1,30p' Shell.swift",
            "cd Sources && cd App && sed -n '1,30p' Shell.swift",
            "cd \(fixture.repo.path)/Sources/App && sed -n '1,30p' Shell.swift",
        ]
        for (index, command) in commands.enumerated() {
            let cold = try fixture.classified(command: command)
            #expect(cold.readPaths(from: fixture.repo.path) == [fixture.file], "\(command)")
            #expect(fixture.verdict(cold, session: "cold\(index)").token == "in-place", "\(command)")
        }
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let unanswerable = commands.flatMap { command in
            [command.replacingOccurrences(of: "sed", with: "LC_ALL=C sed"), command + " > /dev/null"]
        }

        for command in commands + unanswerable {
            #expect(try fixture.verdict(fixture.classified(command: command)).line == "allowed\t\tnoLookup", "\(command)")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.stores.appendingPathComponent("suppressions.jsonl").path))
    }

    /// A move the hook cannot follow — a computed word, `cd -`, a subshell, a `cd` behind `||`, `pushd`, a directory that is not there — leaves a located file's window in a shape no answer covers where it always was: not placed, so let through as a lookup nothing answered.
    @Test(arguments: [
        "cd $X && LC_ALL=C sed -n '1,30p' Shell.swift",
        "cd - && LC_ALL=C sed -n '1,30p' Shell.swift",
        "(cd Sources/App && sed -n '1,30p' Shell.swift)",
        "true || cd Sources/App && LC_ALL=C sed -n '1,30p' Shell.swift",
        "pushd Sources/App && LC_ALL=C sed -n '1,30p' Shell.swift",
        "cd Sources/Nope && LC_ALL=C sed -n '1,30p' Shell.swift",
    ])
    func aWindowBehindAMoveTheHookCannotFollowIsNotPlaced(command: String) throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])

        #expect(try fixture.verdict(fixture.classified(command: command)).line == "allowed\t\tnotAnswerable")
    }

    /// A `..` operand behind a `cd` into a symbolic link names the file where the link points, as the file system reads it: the located file the path names as written is not the one read, so the window is let through as a lookup nothing answered, never judged no lookup on the strength of the wrong file.
    @Test func aClimbingWindowBehindACdIntoALinkIsPlacedWhereTheLinkPoints() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let reached = fixture.repo.appendingPathComponent("Other/Sources/App")
        try FileManager.default.createDirectory(at: reached, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.repo.appendingPathComponent("Other/Deep"), withIntermediateDirectories: true)
        try "struct Shell {}\n".write(to: reached.appendingPathComponent("Shell.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.repo.appendingPathComponent("Link"), withDestinationURL: fixture.repo.appendingPathComponent("Other/Deep"))
        // Named in full, since a relative target also locates a file whose path ends in it.
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": fixture.file])

        let lookup = try fixture.classified(command: "cd Link && LC_ALL=C sed -n '1,30p' ../Sources/App/Shell.swift")

        #expect(fixture.verdict(lookup).line == "allowed\t\tnotAnswerable")
    }

    /// A located file's window beside a grep leaves the grep the lookup: the grep alone is handed to the answerer where the line has an answered shape — marked as leaving the window to print, so the line runs (`HeldWindowLineTests`) — and where it has none the grep is still the lookup nothing answered, logged `notAnswerable` rather than silenced by the window.
    @Test func aLocatedFilesWindowBesideAGrepLeavesTheGrepTheLookup() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let answered = try fixture.classified(command: "sed -n '1,30p' Sources/App/Shell.swift; grep -rn part1 Sources")
        let unanswered = try fixture.classified(command: "(sed -n '1,30p' Sources/App/Shell.swift; grep -rn part1 Sources)")

        #expect(fixture.handed(answered)?.map(\.readPath) == [nil])
        #expect(fixture.verdict(unanswered).line == "allowed\t\tnotAnswerable")
    }

    /// A located file's window beside a grep no answer covers is judged by the grep: logged under the rule the grep alone is logged under, where the window alone is still no lookup with nothing noted.
    @Test func aLocatedFilesWindowBesideAFilteredGrepIsJudgedByTheGrep() throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let window = "sed -n '1,30p' Sources/App/Shell.swift"
        let alone = try fixture.judgedWithTheFileLocated("grep -rn part1 Sources | sort")
        let beside = try fixture.judgedWithTheFileLocated("\(window); grep -rn part1 Sources | sort")
        let unfiltered = try fixture.judgedWithTheFileLocated("(\(window); grep -rn part1 Sources)")
        let only = try fixture.judgedWithTheFileLocated(window)

        #expect(alone.lookup == nil)
        #expect(alone.rules == ["filteredOutput"])
        #expect(beside.lookup == nil)
        #expect(beside.rules == alone.rules)
        #expect(try fixture.verdict(#require(unfiltered.lookup)).line == "allowed\t\tnotAnswerable")
        #expect(only.lookup == nil)
        #expect(only.rules.isEmpty)
    }

    /// A window beside a filtered grep is judged by the grep where only the ledger holds the file — digested by a command-line call, whose usage line names no agent, or edited in this context — and the window alone is still let through with nothing noted.
    @Test func aWindowOfAFileOnlyTheLedgerHoldsBesideAFilteredGrepIsJudgedByTheGrep() throws {
        let window = "sed -n '1,30p' Sources/App/Shell.swift"
        let grep = "grep -rn part1 Sources | sort"
        let digested = try Fixture()
        try digested.lengthen()
        digested.take(tool: "Bash", input: ["command": "sift digest Sources/App/Shell.swift"])
        let edited = try Fixture()
        try edited.lengthen()
        #expect(edited.edit())

        for fixture in [digested, edited] {
            let alone = try fixture.judgedThroughTheLedger(grep)
            let beside = try fixture.judgedThroughTheLedger("\(window); \(grep)")
            #expect(alone.rules == ["filteredOutput"])
            #expect(beside.line == "allowed\t\tnoLookup")
            #expect(beside.rules == alone.rules)
        }
        let digestedWindow = try digested.judgedThroughTheLedger(window)
        let editedWindow = try edited.judgedThroughTheLedger(window)
        #expect(digestedWindow.line == "allowed\t\tnoLookup")
        #expect(digestedWindow.rules.isEmpty)
        #expect(editedWindow.line == "allowed\t\twritten")
        #expect(editedWindow.rules.isEmpty)
    }

    /// The `--command` form judges a held window beside a filtered grep as the stdin payload carrying that command does, rather than finding no line to judge the grep on.
    @Test func theCommandFlagJudgesAHeldWindowBesideAFilteredGrepAsThePayloadDoes() throws {
        let command = "sed -n '1,30p' Sources/App/Shell.swift; grep -rn part1 Sources | sort"
        let edited = try Fixture()
        try edited.lengthen()
        #expect(edited.edit())

        let flag = try edited.judgedThroughTheLedger(command, asFlag: true)
        let payload = try edited.judgedThroughTheLedger(command)
        #expect(flag.line == "allowed\t\tnoLookup")
        #expect(flag.line == payload.line)
        #expect(flag.rules == ["filteredOutput"])
        #expect(flag.rules == payload.rules)
    }

    /// A window of a file this context holds, or a whole read of a digested one, beside a grep judges the grep's name by the gate the caller injected, not a live one: a replay judges every name against its snapshot.
    @Test(arguments: [false, true])
    func aGrepBesideHeldReadsIsJudgedByTheInjectedGate(digested: Bool) throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        if digested {
            fixture.take(tool: "Bash", input: ["command": "sift digest Sources/App/Shell.swift"])
        } else {
            #expect(fixture.edit())
        }
        let read = digested ? "cat" : "sed -n '1,30p'"
        let command = "\(read) Sources/App/Shell.swift; rg QzxNeverDeclared Sources"

        let declared = try Fixture.recorded { try fixture.judgedThroughTheLedger(command, recording: $0, couldAnswer: { _, _ in true }) }
        let undeclared = try Fixture.recorded { try fixture.judgedThroughTheLedger(command, recording: $0, couldAnswer: { _, _ in false }) }

        #expect(!declared.contains("unknownName"), "\(declared)")
        #expect(undeclared.contains("unknownName"), "\(undeclared)")
    }

    /// A whole read of a file whose digest this context holds still lets the line through, but a filtered grep beside it is logged under its own rule before the read's, in either form of the hook; the read alone logs only its own.
    @Test func aWholeReadOfADigestedFileBesideAFilteredGrepStillLogsTheGrep() throws {
        let read = "cat Sources/App/Shell.swift"
        let digested = try Fixture()
        try digested.lengthen()
        digested.take(tool: "Bash", input: ["command": "sift digest Sources/App/Shell.swift"])

        for asFlag in [false, true] {
            let beside = try digested.judgedThroughTheLedger("\(read); grep -rn part1 Sources | sort", asFlag: asFlag)
            #expect(beside.line == "allowed\t\talreadyDigested")
            #expect(beside.rules == ["filteredOutput", "alreadyDigested"])
        }
        let alone = try digested.judgedThroughTheLedger(read)

        #expect(alone.line == "allowed\t\talreadyDigested")
        #expect(alone.rules == ["alreadyDigested"])
    }

    /// The rule a grep beside held reads is logged under names the call it judged, as does the read's own entry.
    @Test func aGrepJudgedBesideHeldReadsIsLoggedAgainstItsCall() throws {
        let grep = "grep -rn part1 Sources | sort"
        let digested = try Fixture()
        try digested.lengthen()
        digested.take(tool: "Bash", input: ["command": "sift digest Sources/App/Shell.swift"])

        let window = try AdviceAgreementTests.Recording()
        let whole = try AdviceAgreementTests.Recording()
        defer {
            window.cleanup()
            whole.cleanup()
        }
        _ = try digested.judgedThroughTheLedger("sed -n '1,30p' Sources/App/Shell.swift; \(grep)", recording: window)
        _ = try digested.judgedThroughTheLedger("cat Sources/App/Shell.swift; \(grep)", recording: whole)

        #expect(window.rules == ["filteredOutput"])
        #expect(window.calls == ["toolu_b1"])
        #expect(whole.rules == ["filteredOutput", "alreadyDigested"])
        #expect(whole.calls == ["toolu_b1", "toolu_b1"])
    }

    /// A window is located only by an answer that located that file: a digest the renderer resolved to a same-named file elsewhere leaves it cold, answered in place — the root's `Shell.swift` for `Sources/App/Shell.swift`, `Sources/App/Shell.swift` for the same path deeper in the tree, and the file declaring `Shell` for another file of that name.
    @Test(arguments: [
        ("Shell.swift", "Shell.swift", "Sources/App/Shell.swift"),
        ("Sources/App/Shell.swift", "Sources/App/Shell.swift", "Other/Sources/App/Shell.swift"),
        ("Shell", "Sources/App/Shell.swift", "Shell.swift"),
    ])
    func aWindowOfASameNamedFileIsStillAnsweredInPlace(target: String, digested: String, sameNamed: String) async throws {
        let fixture = try Fixture()
        try fixture.lengthen()
        let other = try String(contentsOfFile: fixture.file, encoding: .utf8).replacing("struct Shell", with: "struct Widget")
        try MCPTestRepo.add(["Shell.swift": other, "Other/Sources/App/Shell.swift": other], to: fixture.repo)
        try await fixture.index()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": target])

        #expect(try fixture.verdict(fixture.classified(command: "sed -n '1,30p' \(digested)")).line == "allowed\t\tnoLookup")
        #expect(try fixture.verdict(fixture.classified(command: "sed -n '1,30p' \(sameNamed)")).token == "in-place")
    }
}

extension AlreadyDigestedReadTests {
    /// A repository holding `Shell.swift`, and every store the hook writes, somewhere this test owns.
    struct Fixture {
        let repo: URL
        let stores: URL

        /// The fixture over `repo`, a repository declaring `Shell`, else one made for it.
        init(repo: URL? = nil) throws {
            self.repo = try repo ?? MCPTestRepo.make(declaring: "Shell")
            stores = try TemporaryDirectory.make("digested-stores")
        }

        var file: String {
            repo.appendingPathComponent("Sources/App/Shell.swift").path
        }

        /// Brings a real syntactic index up to date over `repo`, so a bare-name target resolves to the file that actually declares it rather than merely matching its stem.
        func index() async throws {
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: stores.appendingPathComponent("advice"))
        }

        func context(_ session: String, agent: String? = "a1") -> AdviceContext {
            AdviceContext.resolve(sessionID: session, transcriptPath: nil, agentID: agent ?? "")
        }

        /// The rules a judgment logged, in order.
        static func recorded(_ judge: (AdviceAgreementTests.Recording) throws -> (line: String, rules: [String])) throws -> [String] {
            let recording = try AdviceAgreementTests.Recording()
            defer { recording.cleanup() }
            return try judge(recording).rules
        }

        /// The hook seeing an index call made in session `s1`, agent `a1` by default.
        func take(tool: String, input: [String: Any], agent: String? = "a1") {
            var payload: [String: Any] = ["tool_name": tool, "tool_input": input]
            if let agent {
                payload["agent_id"] = agent
            }
            _ = PreToolUseCommand.adviceTaken(
                session: "s1",
                context: context("s1", agent: agent),
                payload: payload,
                cwd: repo.path,
                ledger: ledger,
                callers: CallAttribution(directory: stores.appendingPathComponent("callers"))
            )
        }

        /// Makes the file declaring `name` — `Shell.swift` unless told otherwise — long enough that its digest is worth offering, which the tiny file the repository starts with is not.
        func lengthen(_ name: String = "Shell") throws {
            let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
            try ("/// The test type.\nstruct \(name) {\n" + members.joined(separator: "\n") + "\n}\n")
                .write(to: repo.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }

        /// The hook's own classification of a shell command run in the repository, with the re-runs the ledger allows in `session`.
        func classified(command: String, rerunIn session: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            let key = context(session).key
            return try #require(
                PreToolUseCommand.lookup(
                    command: command,
                    payload: [:],
                    in: repo.path,
                    noting: suppressions,
                    couldAnswer: { _, _ in true },
                    allowed: { ledger.rerunsAllowed(session: key, among: $0) }
                ),
                sourceLocation: sourceLocation
            )
        }

        /// The calls the hook hands its answerer for `lookup` in session `s1`, or `nil` where it hands it nothing.
        func handed(_ lookup: PreToolUseCommand.Lookup) -> [InPlaceCall]? {
            var handed: [InPlaceCall]?
            _ = PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: context("s1"),
                payload: ["agent_id": "a1"],
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: stores.appendingPathComponent("usage.jsonl")),
                suppressions: suppressions,
                answerer: { match, _, _ in
                    handed = match.calls
                    return .withheld(.overSize)
                }
            )
            return handed
        }

        /// The hook's own classification of a shell command run in the repository in session `s1`, whose usage log holds a digest of `Shell.swift`, and the rules it logged deciding it.
        func judgedWithTheFileLocated(_ command: String) throws -> (lookup: PreToolUseCommand.Lookup?, rules: [String]) {
            let usage = try DigestedFilesTests.UsageLogFile([
                ["tool": "digest", "target": "Sources/App/Shell.swift", "root": repo.path, "ms": 3, "ok": true, "session": "s1", "outBytes": 900, "srcBytes": 12000],
            ])
            let recording = try AdviceAgreementTests.Recording()
            defer {
                usage.cleanup()
                recording.cleanup()
            }
            let lookup = PreToolUseCommand.lookup(
                command: command,
                payload: ["session_id": "s1"],
                in: repo.path,
                noting: recording.log,
                digested: usage.digested,
                couldAnswer: { _, _ in true }
            )
            return (lookup, recording.rules)
        }

        /// The hook seeing an edit of `Shell.swift` in session `s1`, agent `a1`, and whether it recorded one.
        func edit() -> Bool {
            let payload: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": file], "agent_id": "a1"]
            return PreToolUseCommand.notesWrite(context: context("s1"), payload: payload, cwd: repo.path, ledger: ledger)
        }

        /// The hook's verdict line on a shell command run in the repository in session `s1`, agent `a1`, as it decides one — the lookup, then its outcome — with an empty usage log, so that anything held is held through the ledger alone, and the rules it logged deciding it.
        ///
        /// The command comes in a stdin payload whose call is `toolu_b1`, or, `asFlag`, as `--command` hands it over: beside an empty payload. The log is written to `given` where there is one, left for the caller to read and clean up.
        func judgedThroughTheLedger(
            _ command: String,
            asFlag: Bool = false,
            recording given: AdviceAgreementTests.Recording? = nil,
            couldAnswer: @escaping (String, String?) -> Bool = { _, _ in true }
        ) throws -> (line: String, rules: [String]) {
            let usage = try DigestedFilesTests.UsageLogFile([])
            let recording = try given ?? AdviceAgreementTests.Recording()
            defer {
                usage.cleanup()
                if given == nil {
                    recording.cleanup()
                }
            }
            let payload: [String: Any] = asFlag
                ? [:]
                : ["session_id": "s1", "agent_id": "a1", "tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_b1"]
            let key = context("s1").key
            guard let lookup = PreToolUseCommand.lookup(
                command: asFlag ? command : nil,
                payload: payload,
                in: repo.path,
                noting: recording.log,
                digested: usage.digested,
                couldAnswer: couldAnswer,
                allowed: { ledger.rerunsAllowed(session: key, among: $0) }
            ) else {
                return (PreToolUseCommand.Verdict(token: "allowed", rule: "noLookup").line, recording.rules)
            }
            let verdict = PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: context("s1"),
                payload: payload,
                command: asFlag ? command : nil,
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: stores.appendingPathComponent("usage.jsonl")),
                suppressions: recording.log,
                answerer: { _, _, _ in .withheld(.overSize) },
                couldAnswer: couldAnswer
            ).verdict
            return (verdict.line, recording.rules)
        }

        /// The hook's own classification of a shell command run in the repository.
        func classified(command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(
                PreToolUseCommand.lookup(command: command, payload: [:], in: repo.path, noting: suppressions, couldAnswer: { _, _ in true }),
                sourceLocation: sourceLocation
            )
        }

        /// The hook's own classification of a `Read` of the file starting at line `offset`.
        func classified(rangedReadFrom offset: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(
                PreToolUseCommand.lookup(
                    command: nil,
                    payload: ["tool_name": "Read", "tool_input": ["file_path": file, "offset": offset, "limit": 30]],
                    in: repo.path,
                    noting: suppressions,
                    couldAnswer: { _, _ in true }
                ),
                sourceLocation: sourceLocation
            )
        }

        var suppressions: SuppressionLog {
            SuppressionLog(fileURL: stores.appendingPathComponent("suppressions.jsonl"))
        }

        func shellRead(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            let match: InPlaceShape.Match = try #require(
                InPlaceShape.match(forShell: command, in: repo.path),
                sourceLocation: sourceLocation
            )
            return PreToolUseCommand.Lookup(
                key: command,
                suggestion: IndexSuggestion(call: "digest Sources/App/Shell.swift", yields: "every member"),
                textSearch: nil,
                inPlace: match,
                rule: "ShellAdvice"
            )
        }

        func wholeRead() -> PreToolUseCommand.Lookup {
            PreToolUseCommand.Lookup(
                key: "Read \(file)",
                suggestion: IndexSuggestion(call: "digest Sources/App/Shell.swift", yields: "every member"),
                textSearch: nil,
                readPath: file,
                inPlace: InPlaceShape.match(forRead: file, in: repo.path),
                rule: "ReadAdvice"
            )
        }

        /// The hook's decision on `lookup`, with an answerer that always answers in place.
        func verdict(_ lookup: PreToolUseCommand.Lookup, session: String = "s1", agent: String? = "a1") -> PreToolUseCommand.Verdict {
            let answered = InPlaceAnswerer.Answered(
                reason: "answered",
                calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Shell.swift", bytes: WorthAnsweringFixture.answerBytes)],
                root: repo.path,
                milliseconds: 1
            )
            var payload: [String: Any] = [:]
            if let agent {
                payload["agent_id"] = agent
            }
            return PreToolUseCommand.outcome(
                to: lookup,
                session: session,
                context: context(session, agent: agent),
                payload: payload,
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: stores.appendingPathComponent("usage.jsonl")),
                suppressions: SuppressionLog(fileURL: stores.appendingPathComponent("suppressions.jsonl")),
                answerer: { _, _, _ in .answered(answered) }
            ).verdict
        }
    }
}
