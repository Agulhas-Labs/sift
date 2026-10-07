//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay --against`: each call of one replay put to this build's hook and to another binary's, with only the calls the two judge differently listed.
@Suite(.temporaryDirectories, .hermeticIndexes) struct ReplayAgainstTests {
    /// A cold `cat` this build answers in place and a stub binary lets through as located is listed under the stub's rule → this build's, with its call as `--shapes` shapes it.
    @Test func aCallTheOtherBinaryJudgesDifferentlyIsGroupedByBothRules() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let stub = try Self.stubBinary(verdict: #"{"hooked":true,"rule":"noLookup","token":"allowed"}"#, located: true)

        let section = try await Self.comparison(of: transcript, against: stub)

        let group = try #require(section.firstIndex { $0.hasPrefix("         1  noLookup → ") }, "\(section)")

        #expect(section[group] == "         1  noLookup → ShellAdvice", "\(section)")
        #expect(section[group + 1] == "             1  cat <file>", "\(section)")
        #expect(!section[group + 1].contains("Depot"), "\(section)")
        #expect(section.contains("  differ          1  of the 1 calls in the window"), "\(section)")
    }

    /// A cold window the other binary lets through as a located read is out of its replayed share's denominator and in this build's, so the section prints the two denominators on a line of their own.
    ///
    /// A window, because a whole `cat` names no file for its cold lookup and so can never be scored located, by either hook.
    @Test func aWindowOnlyTheOtherBinaryLocatesMovesTheDenominator() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 1,9999p Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let stub = try Self.stubBinary(verdict: #"{"hooked":true,"rule":"noLookup","token":"allowed"}"#, located: true)

        let section = try await Self.comparison(of: transcript, against: stub)

        #expect(section.contains("  denominator  0 → 1  the replayed share's, its → this one's (located 1 → 0, unreplayable 0 → 0, not worth 0 → 0)"), "\(section)")
    }

    /// A cold window this build lets run as `notSmaller` and the other binary lets through as still cold is out of this build's denominator and in the other's, and the denominator line names the not-worth counts of both.
    @Test func aWindowOnlyThisBuildFindsNotWorthMovesTheDenominator() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 100,119p Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false)

        let section = try await Self.comparison(of: transcript, against: stub)

        #expect(section.contains("  denominator  1 → 0  the replayed share's, its → this one's (located 0 → 0, unreplayable 0 → 0, not worth 0 → 1)"), "\(section)")
    }

    /// A call the log records letting run on worth, which this build still finds not worth while the other binary lets it through cold, moves each side's denominator by the one logged call, not twice: without putting it back neither side's total holds it (its own is out as not worth already), so the denominator reads `1 → 0` and the share `100.0% → n/a`; with it put back both totals hold it once, reading `2 → 1` and `50.0% → 100.0%`.
    @Test func aLoggedNotWorthCallTheOtherBinaryLetsThroughColdMovesEachDenominatorOnce() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Ledger"], cwd: root.path),
            TranscriptFixture.indexAnswer(id: "d1", text: "struct Ledger"),
            TranscriptAuditReplayTests.call("sed -n 100,119p Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: root.path, rule: "answerWithheld", call: "c1")
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false)

        let section = try await Self.comparison(of: transcript, against: stub, suppressionLog: log)

        #expect(section.contains("  denominator  2 → 1  the replayed share's, its → this one's (located 0 → 0, unreplayable 0 → 0, not worth 0 → 1)"), "\(section)")
        #expect(section.contains("  replayed share  50.0% → 100.0%  (indexed + recovered 1 → 1)"), "\(section)")
    }

    /// Where the other binary judges every call as this build does, the section says so in one line and lists nothing, with no denominator line.
    @Test func twoHooksThatAgreeListNothing() {
        var context = ContextReplay()
        let verdict = ReplayVerdict(token: "allowed", rule: "noLookup")
        context.compare(verdict, with: verdict, payload: ["tool_name": "Bash", "tool_input": ["command": "cat Sources/App/Depot.swift"]])
        context.compare(nil, with: nil, payload: ["tool_name": "Write"])

        let section = ReplayComparison.lines([context])

        #expect(section.contains("  no difference: the two hooks judge all 2 calls in the window alike"), "\(section)")
        #expect(!section.contains { $0.hasPrefix("  differ") || $0.hasPrefix("  denominator") }, "\(section)")
    }

    /// Hundreds of requests the other binary answers leave no descriptor open behind them, so a replay of thousands of calls never runs out part-way through.
    @Test func manyAnsweredRequestsLeaveNoDescriptorOpen() async throws {
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false)

        try await Self.expectNoDescriptorLeft(requesting: stub.path, in: TemporaryDirectory.make("against").path, failures: 0)
    }

    /// Hundreds of launches that fail, of a binary that is missing or not executable, leave no descriptor open behind them, and every one is counted as failed.
    @Test func manyLaunchesThatFailLeaveNoDescriptorOpen() async throws {
        let scratch = try TemporaryDirectory.make("against")
        let inert = try Self.stubBinary(verdict: Self.allowed, located: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inert.path)

        await Self.expectNoDescriptorLeft(requesting: scratch.appendingPathComponent("missing/sift").path, in: scratch.path, failures: Self.manyRequests)
        await Self.expectNoDescriptorLeft(requesting: inert.path, in: scratch.path, failures: Self.manyRequests)
    }

    /// A request the other binary never answers is given up at its deadline and counted as failed, and its child, which ignores the request to terminate, is killed and reaped rather than left running.
    ///
    /// A watchdog kills the child after half a minute where the hook does not, so a hook that waits for ever fails this test instead of hanging the suite.
    ///
    /// The request is timed, and the watchdog stood down, on the thread that made it: resuming this test afterwards waits on the concurrency pool, which a loaded suite can hold for longer than the deadline itself. An attempt whose child was stopped before it was ready is made again (``DeadlineChild``).
    @Test(.timeLimit(.minutes(2))) func aChildThatNeverAnswersIsKilledAtItsDeadline() async throws {
        let (outcome, pid) = try await DeadlineChild.ready { pidFile in
            let stub = try Self.stubBinary(verdict: Self.allowed, located: false, prelude: DeadlineChild.prelude(writingPidTo: pidFile))
            let directory = pidFile.deletingLastPathComponent().appendingPathComponent("against", isDirectory: true)
            let finished = Self.watch(pidFile)
            return await InPlaceAnswerTests.onItsOwnThread {
                let started = Date()
                // A margin of seconds, so the child has written its pid before the deadline stops it.
                let hook = ExternalReplayHook(binary: stub, directory: directory, timeBudget: 0.1, margin: 3)
                let verdict = hook.verdict(payload: ["tool_name": "Bash", "tool_input": ["command": "echo 1"]], cwd: "/", at: nil, decides: true)
                finished.signal()
                return (rule: verdict?.rule, failures: hook.failures, elapsed: Date().timeIntervalSince(started))
            }
        }

        #expect(outcome.elapsed < Self.watchdog, "the request took \(outcome.elapsed) seconds, so the watchdog stopped the child and the hook did not")
        #expect(outcome.rule == ExternalReplayHook.failedRule)
        #expect(outcome.failures == 1)
        try DeadlineChild.expectGone(pid)
    }

    /// A request the other binary fails is listed under ``ExternalReplayHook/failedRule``, and the section counts the failures against every request it made.
    @Test func aRequestTheOtherBinaryFailsIsListedAsUnanswered() async throws {
        let scratch = try TemporaryDirectory.make("projects")
        let transcript = scratch.appendingPathComponent("replayed-session.jsonl")
        let lines = try ["echo one", "echo broken", "echo three"].enumerated().map { index, command in
            try TranscriptAuditReplayTests.call(command, id: "c\(index)", cwd: scratch.path, at: "2026-09-20T10:00:0\(index)Z")
        }
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false, prelude: #"case "$(cat)" in *broken*) exit 3 ;; esac"#)

        let section = try await Self.comparison(of: transcript, against: stub)

        #expect(section.contains { $0.hasPrefix("         1  unanswered → ") }, "\(section)")
        #expect(section.contains("  the other binary failed 1 of its 3 requests — each verdict it failed is listed under unanswered"), "\(section)")
    }

    /// This build put against itself, through its own `replay-hook` in a child for every call, judges every call alike.
    @Test func thisBuildAgainstItselfListsNoDifference() async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try await InPlaceAnswerTests.indexedRepository()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let commands = ["cat Sources/App/Depot.swift", "sed -n 10,20p Sources/App/Depot.swift", "grep -n stock Sources/App/Depot.swift", "echo done"]
        let lines = try commands.enumerated().map { index, command in
            try TranscriptAuditReplayTests.call(command, id: "c\(index)", cwd: root.path, at: "2026-09-20T10:00:0\(index)Z")
        }
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.comparison(of: transcript, against: sift)

        #expect(section.contains("  no difference: the two hooks judge all 4 calls in the window alike"), "\(section)")
        #expect(!section.contains { $0.contains("the other binary failed") }, "\(section)")
    }

    /// `replay-hook` refuses a state directory that is, through a symlink, the one the live hook keeps its ledger in, and writes nothing there.
    @Test func replayHookRefusesTheLiveStateDirectory() async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let scratch = try TemporaryDirectory.make("live")
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let live = home.appendingPathComponent(".sift", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("state")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: live)
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_ADVICE_DIR"] = live.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = live.appendingPathComponent("usage.jsonl").path
        let variables = environment

        let status = await InPlaceAnswerTests.onItsOwnThread {
            let process = Process()
            process.executableURL = sift
            process.arguments = ["replay-hook", "--state", link.path, "--cwd", scratch.path, "--answered"]
            process.environment = variables
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Int32(-1) }
            try? input.fileHandleForWriting.write(contentsOf: Data(#"{"tool_name":"mcp__sift__digest","tool_input":{"target":"Depot"}}"#.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }

        #expect(status != 0 && status != -1, "replay-hook exited \(status)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path).isEmpty)
    }

    /// A binary that never answers the question whether it has a `replay-hook` is stopped at the probe's deadline and counted as having none, and its child, which ignores the request to terminate, is killed and reaped.
    ///
    /// A watchdog kills the child after half a minute where the probe does not, so a probe that waits for ever fails this test instead of hanging the suite.
    ///
    /// The probe is timed on its own thread, and a child stopped before it was ready is made again, as the request above is.
    @Test(.timeLimit(.minutes(2))) func aChildThatHangsOnItsHelpIsKilledAtItsDeadline() async throws {
        let (probe, pid) = try await DeadlineChild.ready { pidFile in
            let stub = try Self.script(DeadlineChild.prelude(writingPidTo: pidFile))
            let finished = Self.watch(pidFile)
            return await InPlaceAnswerTests.onItsOwnThread {
                let started = Date()
                // A deadline well short of the watchdog's, with room for the child to write its pid first.
                let supported = ExternalReplayHook.isSupported(by: stub, within: 3)
                finished.signal()
                return (supported: supported, elapsed: Date().timeIntervalSince(started))
            }
        }

        #expect(probe.elapsed < Self.watchdog, "the probe took \(probe.elapsed) seconds, so the watchdog stopped the child and the probe did not")
        #expect(!probe.supported)
        try DeadlineChild.expectGone(pid)
    }

    /// `audit --replay --against` puts no call to a binary whose index is at another schema version than this build's, or whose version it cannot establish, since each would rebuild every live index the replay touches at its own version in turn; it refuses up front, naming both versions, and replays a binary at this build's version.
    ///
    /// The stub writes the version it is given into the store of the repository it is asked to index, and logs every request it gets, so the test sees whether any call reached it and that the repository it indexed is gone afterwards.
    @Test(arguments: [IndexSchema.version - 1, nil, IndexSchema.version])
    func anOtherBinaryIsReplayedOnlyAtThisBuildsSchema(schema: Int32?) async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let scratch = try TemporaryDirectory.make("schema")
        let log = scratch.appendingPathComponent("requests.log")
        let fingerprint = try await Self.realResolutionFingerprint(sift: sift)
        let indexing = schema.map {
            #"mkdir -p "$3/.sift" && /usr/bin/sqlite3 "$3/.sift/index.db" 'PRAGMA user_version=\#($0); CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta(key, value) VALUES("resolution_fingerprint", "\#(fingerprint)");'; exit 0"#
        } ?? "exit 1"
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false, prelude: #"echo "$*" >> '\#(log.path)'; case "$1" in index) \#(indexing) ;; esac"#)
        let projects = scratch.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [TranscriptAuditReplayTests.call("echo one", id: "c1", cwd: scratch.path, at: "2026-09-20T10:00:00Z")]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let live = home.appendingPathComponent(".sift", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_ADVICE_DIR"] = live.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = live.appendingPathComponent("usage.jsonl").path
        let variables = environment

        let (status, errors) = await InPlaceAnswerTests.onItsOwnThread {
            let process = Process()
            process.executableURL = sift
            process.arguments = ["audit", "--replay", "--projects", projects.path, "--transcript", transcript.path, "--against", stub.path]
            process.environment = variables
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            guard (try? process.run()) != nil else { return (Int32(-1), "") }
            let text = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        let requests = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let probe = try #require(requests.first { $0.hasPrefix("index --root ") }, "\(requests)")
        #expect(!FileManager.default.fileExists(atPath: String(probe.dropFirst("index --root ".count))), "the repository it indexed is left behind")
        let replayed = requests.contains { $0.hasPrefix("replay-hook --state ") }
        if schema == IndexSchema.version {
            #expect(status == 0, "\(errors)")
            #expect(replayed, "\(requests)")
        } else {
            let refusal = schema.map { "keeps its index at schema \($0), this build at \(IndexSchema.version)" } ?? "did not show which index schema it keeps"
            #expect(status != 0 && status != -1, "audit exited \(status)")
            #expect(errors.contains(refusal), "\(errors)")
            #expect(!replayed, "\(requests)")
        }
    }

    /// A probe whose own base directory cannot be written is refused for that reason, never read as the other binary having written no index.
    @Test func aProbeBaseThatCannotBeWrittenIsRefusedForItsOwnReason() throws {
        let scratch = try TemporaryDirectory.make("unwritable-probe")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path) }
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false)

        let outcome = ExternalReplayHook.schemaVersion(of: stub, probeBase: scratch, within: 10)

        guard case let .setupFailed(reason) = outcome else {
            Issue.record("expected setupFailed, got \(outcome)")
            return
        }

        #expect(!reason.isEmpty)
        #expect(!reason.contains("wrote no index"), "\(reason)")
    }

    /// The probe moves the other binary's home away from the live one before asking it to index, so nothing it writes lands in a session's real `~/.sift`.
    @Test func theProbeMovesTheOtherBinarysHomeAwayFromTheRealOne() throws {
        let scratch = try TemporaryDirectory.make("home-probe")
        let seen = scratch.appendingPathComponent("home.txt")
        let stub = try Self.script(#"echo "$CFFIXED_USER_HOME" > '\#(seen.path)'; exit 1"#)

        _ = ExternalReplayHook.schemaVersion(of: stub, within: 10)

        let recorded = (try? String(contentsOf: seen, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        #expect(!recorded.isEmpty)
        #expect(recorded != NSHomeDirectory())
    }

    /// A binary at this build's own schema but another resolution fingerprint is refused too: the schema alone is not enough to say the two would attribute files the same way.
    @Test func anOtherBinaryAtAnotherResolutionFingerprintIsRefused() async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let scratch = try TemporaryDirectory.make("fingerprint")
        let indexing = #"mkdir -p "$3/.sift" && /usr/bin/sqlite3 "$3/.sift/index.db" 'PRAGMA user_version=\#(IndexSchema.version); CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta(key, value) VALUES("resolution_fingerprint", "v0:not-this-build");'; exit 0"#
        let stub = try Self.stubBinary(verdict: Self.allowed, located: false, prelude: #"case "$1" in index) \#(indexing) ;; esac"#)
        let projects = scratch.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [TranscriptAuditReplayTests.call("echo one", id: "c1", cwd: scratch.path, at: "2026-09-20T10:00:00Z")]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let live = home.appendingPathComponent(".sift", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_ADVICE_DIR"] = live.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = live.appendingPathComponent("usage.jsonl").path
        let variables = environment

        let (status, errors) = await InPlaceAnswerTests.onItsOwnThread {
            let process = Process()
            process.executableURL = sift
            process.arguments = ["audit", "--replay", "--projects", projects.path, "--transcript", transcript.path, "--against", stub.path]
            process.environment = variables
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            guard (try? process.run()) != nil else { return (Int32(-1), "") }
            let text = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        #expect(status != 0 && status != -1, "audit exited \(status)")
        #expect(errors.contains("resolution fingerprint"), "\(errors)")
        #expect(errors.contains("v0:not-this-build"), "\(errors)")
    }

    /// The section closes on both hooks' replayed shares, its → this one's, each matching what `TranscriptReplay.shareLine` computes for that hook alone over the same tally.
    ///
    /// The other binary locates two of the five calls and this build alone finds three not worth, so the two sides' denominators (3 and 2) differ from each other and from the five calls' plain total — a denominator computed over that plain total instead would print the wrong shares on both sides.
    @Test func bothHooksReplayedSharesArePrintedAfterTheDenominator() {
        var context = ContextReplay()
        context.tally.cold = 5
        context.replay.count(.recovered("noLookup → digest"))
        context.against.count(.located, by: 2)
        context.replay.count(.notWorth(InPlaceAnswerer.Withholding.notSmaller.rawValue), by: 3)

        let section = ReplayComparison.lines([context])
        let totals = context.tally.scored
        let oursShare = TranscriptReplay.shareLine(totals, replay: context.replay)
        let theirsShare = TranscriptReplay.shareLine(totals, replay: context.against)

        #expect(section.contains("  denominator  3 → 2  the replayed share's, its → this one's (located 2 → 0, unreplayable 0 → 0, not worth 0 → 3)"), "\(section)")
        #expect(section.last == "  replayed share  0.0% → 50.0%  (indexed + recovered 0 → 1)", "\(section)")
        #expect(theirsShare.hasPrefix("0% = (indexed 0 + recovered 0) / 3 "), "\(theirsShare)")
        #expect(oursShare.hasPrefix("50% = (indexed 0 + recovered 1) / 2 "), "\(oursShare)")
    }

    /// How long a deadline test waits before killing a child the code under test left running: past the deadline and the stop that follows it, however loaded the machine.
    private static let watchdog: TimeInterval = 30

    /// The verdict every stub gives unless a test needs another.
    private static var allowed: String {
        #"{"hooked":true,"rule":"noLookup","token":"allowed"}"#
    }

    /// Enough requests that one descriptor left open by each stands far above any the child opens for itself.
    private static var manyRequests: Int {
        300
    }

    /// Expects ``manyRequests`` requests to `binary` to leave the open descriptor count where it was, with `failures` of them failed.
    ///
    /// They run in a child process that runs nothing else, since a count taken in the test runner moves with every test running beside this one; there, one end left open by each request moves it by hundreds.
    private static func expectNoDescriptorLeft(requesting binary: String, in directory: String, failures: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await #expect(processExitsWith: .success, sourceLocation: sourceLocation) { [binary = binary as String, directory = directory as String, failures = failures as Int] in
            let hook = ExternalReplayHook(binary: URL(fileURLWithPath: binary), directory: URL(fileURLWithPath: directory), timeBudget: 30)
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "echo 1"]]
            let before = SwiftTreeDescriptorTests.openDescriptors()
            for _ in 0 ..< ReplayAgainstTests.manyRequests {
                _ = hook.verdict(payload: payload, cwd: "/", at: nil, decides: true)
            }
            let after = SwiftTreeDescriptorTests.openDescriptors()
            #expect(hook.requests == ReplayAgainstTests.manyRequests)
            #expect(hook.failures == failures)
            #expect(after <= before + 4, "open descriptors went from \(before) to \(after)")
        }
    }

    /// A watchdog that kills the child whose pid is in `pidFile` after ``watchdog`` seconds, unless the semaphore it returns is signalled first.
    private static func watch(_ pidFile: URL) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            guard finished.wait(timeout: .now() + Self.watchdog) == .timedOut, let pid = DeadlineChild.pid(in: pidFile) else { return }
            kill(pid, SIGKILL)
        }
        return finished
    }

    /// The comparison `audit --replay --against` prints for `transcript`, under the roomy time budget and on a thread of its own.
    private static func comparison(of transcript: URL, against binary: URL, suppressionLog: URL? = nil) async throws -> [String] {
        let scratch = try TemporaryDirectory.make("replay")
        // The child reads a home of its own with no repository registered, as the in-process hook reads the empty registry the suite scopes, so neither sees this machine's `~/.sift/roots.json`.
        let home = try TemporaryDirectory.make("home")
        return try await InPlaceAnswerTests.onItsOwnThread {
            Result {
                try AuditCommand.replaySection(
                    projectsDirectory: transcript.deletingLastPathComponent(),
                    since: nil,
                    transcript: transcript.path,
                    scratch: scratch,
                    timeBudget: InPlaceAnswerTests.roomy,
                    against: binary,
                    againstEnvironment: ["CFFIXED_USER_HOME": home.path],
                    suppressionLog: suppressionLog
                )
            }
        }.get()
    }

    /// The resolution fingerprint `sift` itself stamps a fresh index of an empty repository with, read back through `sqlite3` rather than any of this fix's own Swift API, so reverting the fix cannot take this reading down with it.
    static func realResolutionFingerprint(sift: URL) async throws -> String {
        let repository = try TemporaryDirectory.make("real-fingerprint")
        let home = try TemporaryDirectory.make("real-fingerprint-home")
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repository.path]
        try git.run()
        git.waitUntilExit()
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        let variables = environment
        return await InPlaceAnswerTests.onItsOwnThread {
            let index = Process()
            index.executableURL = sift
            index.arguments = ["index", "--root", repository.path]
            index.environment = variables
            index.standardOutput = FileHandle.nullDevice
            index.standardError = FileHandle.nullDevice
            guard (try? index.run()) != nil else { return "" }
            index.waitUntilExit()

            let read = Process()
            read.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            read.arguments = [repository.appendingPathComponent(".sift/index.db").path, "SELECT value FROM meta WHERE key='resolution_fingerprint';"]
            let output = Pipe()
            read.standardOutput = output
            read.standardError = FileHandle.nullDevice
            guard (try? read.run()) != nil else { return "" }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            read.waitUntilExit()
            return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// A stand-in for another sift binary's `replay-hook`: every verdict it gives is `verdict`, and every file is located only by answers where `located`, with `prelude` run first on every request.
    private static func stubBinary(verdict: String, located: Bool, prelude: String = "") throws -> URL {
        try script("""
        case " $* " in *" --help "*) exit 0 ;; esac
        \(prelude)
        cat > /dev/null
        case " $* " in
          *" --answered "*) echo '{}' ;;
          *" --located "*) echo '{"located":\(located)}' ;;
          *) echo '\(verdict)' ;;
        esac
        """)
    }

    /// A stand-in for another sift binary that runs `body` for every request, whatever it asks.
    private static func script(_ body: String) throws -> URL {
        let script = try TemporaryDirectory.make("stub").appendingPathComponent("sift")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
