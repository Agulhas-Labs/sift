//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the half of the orphaned-server problem that parent death cannot reach: a person stopping a server whose client went quiet with its parent still alive.
///
/// **What is worth pinning here is every case where nothing is stopped.** A reap that stops what it was asked to is the easy half — a `kill` either works or reports why. The half that costs is the one that stops something it should not have, and each of those has a named guard: the caller's own conversation, the caller's own ancestry, and a server with a recent sign of life. Every one of these tests exists because getting it wrong takes a working session's index away mid-run, which is the defect this whole area of the codebase was built to remove.
@Suite(.temporaryDirectories)
struct ServerRosterTests {
    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    private static func stamp(_ offset: TimeInterval) -> String {
        ServerLifecycleLog.stamp(now.addingTimeInterval(offset))
    }

    /// A start line for a server that began the given number of seconds before now.
    private static func start(pid: Int32, secondsAgo: TimeInterval, root: String = "/repo", session: String? = nil) -> ServerLifecycleEntry {
        ServerLifecycleEntry(event: "start", pid: pid, stamp: stamp(-secondsAgo), root: root, session: session)
    }

    private static func stop(pid: Int32, secondsAgo: TimeInterval) -> ServerLifecycleEntry {
        ServerLifecycleEntry(event: "stop", pid: pid, stamp: stamp(-secondsAgo), reason: "input-closed")
    }

    /// What every report call in this suite says it read, where the reading itself is not the subject.
    private static let evidence = ServerRosterReport.Evidence(
        lifecycleLog: "/tmp/server.jsonl",
        lifecycleEntries: 4,
        usageLog: "/tmp/usage.jsonl",
        sessionsWithActivity: 3,
        callerIsNamed: true
    )

    private static func roster(
        _ entries: [ServerLifecycleEntry],
        callerSession: String? = nil,
        callerTree: Set<Int32> = [],
        lastAnswered: [String: Date] = [:]
    ) -> [RunningServer] {
        ServerRoster.running(
            entries: entries,
            now: now,
            callerSession: callerSession,
            callerTree: callerTree,
            lastAnswered: lastAnswered,
            isRunning: { _ in true }
        )
    }

    // MARK: - Who is on the roster

    /// A server that recorded a stop is not one this machine believes is running.
    @Test
    func onlyStartsThatNoStopEverClosedAreOnTheRoster() {
        let entries = [
            Self.start(pid: 100, secondsAgo: 7200),
            Self.start(pid: 200, secondsAgo: 3600),
            Self.stop(pid: 100, secondsAgo: 60),
        ]

        #expect(Self.roster(entries).map(\.pid) == [200])
    }

    /// What the roster carries about a server is what a person needs to decide about it: where, whose, since when, and when last heard from.
    @Test
    func aRosterEntryCarriesTheRootSessionAndLastAnswer() {
        let answered = Self.now.addingTimeInterval(-4000)
        let roster = Self.roster(
            [Self.start(pid: 300, secondsAgo: 20000, root: "/repo/app", session: "one")],
            lastAnswered: ["one": answered]
        )

        #expect(roster.count == 1)
        #expect(roster[0].root == "/repo/app")
        #expect(roster[0].session == "one")
        #expect(roster[0].lastAnswered == answered)
        #expect(roster[0].lastSignOfLife == answered)
    }

    /// The usage log is keyed by session, so an answer from before this server started was an earlier server's in the same session, and is not this one's.
    @Test
    func anAnswerFromBeforeTheServerStartedIsNotItsLastAnswer() {
        let roster = Self.roster(
            [Self.start(pid: 310, secondsAgo: 3600, session: "one")],
            lastAnswered: ["one": Self.now.addingTimeInterval(-90000)]
        )

        #expect(roster.map(\.lastAnswered) == [nil])
        #expect(roster.map(\.lastSignOfLife) == [Self.now.addingTimeInterval(-3600)])
    }

    // MARK: - The guards

    /// The caller's own server is never a candidate, whatever else is true of it.
    ///
    /// This is the guard that stops the command being the very failure it exists to prevent: a session that reaps by root, and takes its own index with it.
    @Test
    func theCallersOwnSessionIsHeldBack() {
        let roster = Self.roster(
            [
                Self.start(pid: 400, secondsAgo: 90000, session: "mine"),
                Self.start(pid: 401, secondsAgo: 90000, session: "theirs"),
            ],
            callerSession: "mine"
        )

        #expect(roster.first { $0.pid == 400 }?.protection == .ownSession)
        #expect(roster.first { $0.pid == 401 }?.protection == nil)
    }

    /// A server that spawned this process is never a candidate either, whatever the session field says.
    ///
    /// The session guard depends on an environment variable being there; ancestry does not. Two independent facts, because the one that is missing is the one that would have mattered.
    @Test
    func aServerInTheCallersOwnAncestryIsHeldBack() {
        let roster = Self.roster([Self.start(pid: 500, secondsAgo: 90000)], callerTree: [500, 12])

        #expect(roster[0].protection == .ownProcessTree)
    }

    /// A server that answered something recently has a client that is evidently still there.
    @Test
    func aRecentAnswerHoldsAServerBackAndAnOldOneDoesNot() {
        let entries = [
            Self.start(pid: 600, secondsAgo: 90000, session: "busy"),
            Self.start(pid: 601, secondsAgo: 90000, session: "quiet"),
        ]
        let roster = Self.roster(entries, lastAnswered: [
            "busy": Self.now.addingTimeInterval(-30),
            "quiet": Self.now.addingTimeInterval(-ServerRoster.liveWindow - 1),
        ])

        #expect(roster.first { $0.pid == 600 }?.protection == .recentlyAlive(secondsAgo: 30))
        #expect(roster.first { $0.pid == 601 }?.protection == nil)
    }

    /// A server that has answered nothing at all is held back while it is new.
    ///
    /// The hole this closes is the one a purely usage-based reading leaves open: a session thirty seconds old has answered nothing, and so has a corpse from yesterday. Counting the start as a sign of life tells them apart without a second policy.
    @Test
    func aServerThatHasAnsweredNothingIsHeldBackWhileItIsNew() {
        let fresh = Self.roster([Self.start(pid: 700, secondsAgo: 20)])
        let old = Self.roster([Self.start(pid: 701, secondsAgo: ServerRoster.liveWindow + 60)])

        #expect(fresh[0].protection == .recentlyAlive(secondsAgo: 20))
        #expect(old[0].protection == nil)
    }

    /// A sign of life stamped in the future holds a server back rather than exposing it.
    ///
    /// **This is the case that fails open.** `lastSignOfLife` is the newest of the start and the last answer, so a session whose clock runs ahead — a stepped clock, an unsynchronised machine — puts a future date there, and read naively that makes the age negative and takes the protection away entirely. The stronger evidence of life would destroy the protection the weaker evidence alone gives: a server started one second ago, offered for stopping.
    @Test
    func aSignOfLifeInTheFutureHoldsAServerBack() {
        let roster = Self.roster(
            [Self.start(pid: 1600, secondsAgo: 90000, session: "ahead")],
            lastAnswered: ["ahead": Self.now.addingTimeInterval(90)]
        )

        #expect(roster[0].protection == .recentlyAlive(secondsAgo: 0))
    }

    /// A server started seconds ago is held even when its recorded answer sits in the future.
    ///
    /// The same hazard from the other side: the fresh start alone spares it, and the future answer must not remove the sparing.
    @Test
    func aFreshServerIsNotExposedByAFutureAnswer() {
        let roster = Self.roster(
            [Self.start(pid: 1601, secondsAgo: 1, session: "ahead")],
            lastAnswered: ["ahead": Self.now.addingTimeInterval(3600)]
        )

        #expect(roster[0].protection != nil)
    }

    /// The row and the guard read one timestamp the same way.
    ///
    /// Read in opposite directions — the row clamping a future date to "0s ago" while the guard rejects it — the listing would show a reader the strongest possible reason to keep a server on the same line as the tool's decision to kill it.
    @Test
    func aRowAndItsGuardAgreeAboutADateInTheFuture() {
        let roster = Self.roster(
            [Self.start(pid: 1602, secondsAgo: 90000, session: "ahead")],
            lastAnswered: ["ahead": Self.now.addingTimeInterval(120)]
        )
        let text = ServerRosterReport.listing(roster, now: Self.now, evidence: Self.evidence)

        #expect(text.contains("last answered 0s ago"))
        #expect(text.contains("held:"))
    }

    /// Ten minutes is the policy both documents state, so the constant is asserted rather than only referred to.
    ///
    /// Every other test here reads `liveWindow` symbolically, which is right for them and leaves the number itself free to become a day without a single test noticing.
    @Test
    func theLiveWindowIsTenMinutes() {
        #expect(ServerRoster.liveWindow == 600)
    }

    // MARK: - Selection

    /// A stop acts on what it was told to act on: pids by number, a root by subtree.
    @Test
    func aSelectionTakesNamedPidsAndEverythingUnderARoot() {
        let servers = Self.roster([
            Self.start(pid: 800, secondsAgo: 90000, root: "/repo/app"),
            Self.start(pid: 801, secondsAgo: 90000, root: "/repo/web"),
            Self.start(pid: 802, secondsAgo: 90000, root: "/elsewhere"),
        ])

        #expect(ServerRoster.select(from: servers, pids: [802], root: nil).matched.map(\.pid) == [802])
        #expect(ServerRoster.select(from: servers, pids: [], root: "/repo").matched.map(\.pid).sorted() == [800, 801])
        #expect(ServerRoster.select(from: servers, pids: [], root: "/repo/app").matched.map(\.pid) == [800])
    }

    /// A root selects its own subtree and nothing that merely starts with the same letters.
    @Test
    func aRootDoesNotSelectASiblingWhoseNameItIsAPrefixOf() {
        let servers = Self.roster([Self.start(pid: 810, secondsAgo: 90000, root: "/repo-web")])

        #expect(ServerRoster.select(from: servers, pids: [], root: "/repo").matched.isEmpty)
    }

    /// A pid that no running server holds is reported, because that is the answer the caller was after.
    @Test
    func aPidNoRunningServerHoldsIsReportedRatherThanDropped() {
        let servers = Self.roster([Self.start(pid: 900, secondsAgo: 90000)])
        let selection = ServerRoster.select(from: servers, pids: [900, 999], root: nil)

        #expect(selection.matched.map(\.pid) == [900])
        #expect(selection.unmatched == [999])
    }

    /// A root that names the machine is recognised as one, which is what keeps the "reaps whatever it finds" form from existing.
    ///
    /// `/` is a prefix of every absolute path, so one token would select every server on this machine; the home directory does it one level down, and so does anything above it. In a cron there is no session id and no shared ancestry, so nothing else would stand in the way.
    @Test
    func aRootThatNamesTheMachineIsRecognisedAsOne() {
        let home = URL(fileURLWithPath: "/Users/someone")

        #expect(ServerRoster.namesTheWholeMachine("/", home: home))
        #expect(ServerRoster.namesTheWholeMachine("/Users/someone", home: home))
        #expect(ServerRoster.namesTheWholeMachine("/Users", home: home))
        // A scope somebody chose is still a scope, and stays allowed.
        #expect(!ServerRoster.namesTheWholeMachine("/Users/someone/Projects", home: home))
        #expect(!ServerRoster.namesTheWholeMachine("/private/tmp/build", home: home))
    }

    /// A root that would reach the account home is refused even when `HOME` has moved somewhere else entirely.
    @Test
    func aRootAboveTheAccountHomeIsRefusedEvenUnderAMovedHOME() {
        let movedHome = URL(fileURLWithPath: "/tmp/x")
        let accountHome = URL(fileURLWithPath: "/Users/someone")

        #expect(ServerRoster.namesTheWholeMachine("/Users/someone", home: movedHome, accountHome: accountHome))
        #expect(ServerRoster.namesTheWholeMachine("/Users", home: movedHome, accountHome: accountHome))
        #expect(!ServerRoster.namesTheWholeMachine("/Users/someone/Projects", home: movedHome, accountHome: accountHome))
    }

    /// What that refusal prevents, stated as the property rather than as the rule.
    @Test
    func aRootOfSlashWouldOtherwiseSelectEveryServer() {
        let servers = Self.roster([
            Self.start(pid: 1700, secondsAgo: 90000, root: "/Users/someone/one"),
            Self.start(pid: 1701, secondsAgo: 90000, root: "/private/tmp/two"),
        ])

        #expect(ServerRoster.select(from: servers, pids: [], root: "/").matched.count == 2)
        #expect(ServerRoster.namesTheWholeMachine("/"))
    }

    /// A root that matched nothing is a finding, not a silence.
    ///
    /// A mistyped path answered with `nothing to stop` and exit 0 would be indistinguishable from a clean reap, and the exact silence this command's own design says a reap must never give.
    @Test
    func aRootThatMatchedNothingIsReportedAndIsNotACleanRun() {
        let servers = Self.roster([Self.start(pid: 1800, secondsAgo: 90000, root: "/repo/app")])
        let selection = ServerRoster.select(from: servers, pids: [], root: "/repo/typo")
        let outcome = ServerRoster.stopAll(selection, stop: { _ in nil })

        #expect(selection.matched.isEmpty)
        #expect(selection.unmatchedRoot == "/repo/typo")
        #expect(!outcome.didEverythingAsked)
        #expect(ServerRosterReport.outcome(outcome, evidence: Self.evidence).contains("/repo/typo"))
    }

    /// A root that matched something carries no such finding.
    @Test
    func aRootThatMatchedSomethingIsNotReportedAsMissing() {
        let servers = Self.roster([Self.start(pid: 1801, secondsAgo: 90000, root: "/repo/app")])

        #expect(ServerRoster.select(from: servers, pids: [], root: "/repo").unmatchedRoot == nil)
    }

    // MARK: - Stopping

    /// A held-back server is never signalled — not merely reported as spared.
    ///
    /// The distinction is the whole test. A guard that decides correctly and then signals anyway is indistinguishable from a working one in every output the command produces, and would take a live session's index away all the same.
    @Test
    func nothingHeldBackIsEverSignalled() {
        let servers = Self.roster(
            [
                Self.start(pid: 1000, secondsAgo: 90000, session: "mine"),
                Self.start(pid: 1001, secondsAgo: 90000, session: "theirs"),
                Self.start(pid: 1002, secondsAgo: 20),
            ],
            callerSession: "mine"
        )
        let signalled = Signalled()

        let outcome = ServerRoster.stopAll(
            ServerRoster.select(from: servers, pids: [1000, 1001, 1002, 1003], root: nil),
            stop: { pid in
                signalled.record(pid)
                return nil
            }
        )

        #expect(signalled.pids == [1001])
        #expect(outcome.stopped.map(\.pid) == [1001])
        #expect(outcome.heldBack.map(\.pid).sorted() == [1000, 1002])
        #expect(outcome.unmatched == [1003])
        #expect(!outcome.didEverythingAsked)
    }

    /// A kernel that will not stop a server says so, and the answer keeps it apart from one that was spared.
    @Test
    func aRefusedSignalIsAFailureAndNotAStop() {
        let servers = Self.roster([Self.start(pid: 1100, secondsAgo: 90000)])
        let outcome = ServerRoster.stopAll(ServerRoster.select(from: servers, pids: [1100], root: nil), stop: { _ in EPERM })

        #expect(outcome.stopped.isEmpty)
        #expect(outcome.failed == [ServerRoster.Outcome.Failure(pid: 1100, code: EPERM)])
        #expect(!outcome.didEverythingAsked)
    }

    /// Everything asked for happening is what a script reads as a clean run.
    @Test
    func aStopThatDidEverythingAskedSaysSo() {
        let servers = Self.roster([Self.start(pid: 1200, secondsAgo: 90000)])
        let outcome = ServerRoster.stopAll(ServerRoster.select(from: servers, pids: [1200], root: nil), stop: { _ in nil })

        #expect(outcome.didEverythingAsked)
    }

    // MARK: - The evidence the guards rest on

    /// The usage log is read for the newest call each conversation made, and for nothing else.
    @Test
    func theLastAnswerPerSessionIsReadFromTheUsageLog() throws {
        let directory = try TemporaryDirectory.make("roster")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.jsonl")
        let lines = [
            #"{"ts":"2026-09-10T10:00:00Z","tool":"digest","root":"/repo","ok":true,"session":"one"}"#,
            #"{"ts":"2026-09-10T12:30:00Z","tool":"where","root":"/repo","ok":true,"session":"one"}"#,
            #"{"ts":"2026-09-10T11:00:00Z","tool":"digest","root":"/repo","ok":true,"session":"two"}"#,
            #"{"ts":"2026-09-10T13:00:00Z","tool":"digest","root":"/repo","ok":true}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let answered = ServerRoster.lastAnswered(in: file)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")

        #expect(answered["one"] == formatter.date(from: "2026-09-10T12:30:00Z"))
        #expect(answered["two"] == formatter.date(from: "2026-09-10T11:00:00Z"))
        // A call with no session belongs to no server, and inventing a key for it would let one server's
        // silence be answered with another's activity.
        #expect(answered.count == 2)
    }

    /// A usage log that is not there is no evidence, rather than an error or a claim that everything is idle.
    @Test
    func aMissingUsageLogIsNoEvidence() {
        #expect(ServerRoster.lastAnswered(in: URL(fileURLWithPath: "/nonexistent/usage.jsonl")).isEmpty)
    }

    /// The ancestry walk stops rather than looping, whatever the kernel says.
    @Test
    func theProcessTreeWalkTerminates() {
        #expect(ServerRoster.processTree(of: 40, parent: { pid in pid == 40 ? 41 : 1 }) == [40, 41])
        // A chain that came back on itself would otherwise be walked forever.
        #expect(ServerRoster.processTree(of: 50, parent: { pid in pid == 50 ? 51 : 50 }) == [50, 51])
        #expect(ServerRoster.processTree(of: 1, parent: { _ in 1 }).isEmpty)
    }

    // MARK: - What it says before it does anything

    /// A plan says, in the answer itself, that nothing has happened yet.
    ///
    /// The thing being stopped is another session's working index, so the difference between "would stop" and "stopped" may not be something a reader has to infer from which flags they typed.
    @Test
    func aPlanSaysNothingHasBeenStopped() {
        let servers = Self.roster([Self.start(pid: 1300, secondsAgo: 90000, root: "/repo/app")])
        let text = ServerRosterReport.plan(ServerRoster.select(from: servers, pids: [1300], root: nil), now: Self.now, evidence: Self.evidence)

        #expect(text.contains("would stop 1 server"))
        #expect(text.contains("nothing has been stopped"))
        #expect(text.contains("/repo/app"))
    }

    /// A held-back server is named with the evidence that held it, never merely omitted.
    @Test
    func aHeldBackServerIsNamedWithItsReason() {
        let servers = Self.roster([Self.start(pid: 1400, secondsAgo: 90000, session: "mine")], callerSession: "mine")
        let text = ServerRosterReport.plan(ServerRoster.select(from: servers, pids: [1400], root: nil), now: Self.now, evidence: Self.evidence)

        #expect(text.contains("held back:"))
        #expect(text.contains("pid 1400"))
        #expect(text.contains("this session's own server"))
    }

    /// A caller that cannot name itself is told so on every face, including the two that act.
    ///
    /// Said only in the listing, it would reach the one path where nothing is stopped, and so the one place the warning cannot matter. A caller who cannot be recognised is *about to stop things*, and that is the moment to say that the guard which would have spared their own server is inoperative.
    @Test
    func everyFaceSaysWhenTheCallerCannotBeRecognised() {
        let anonymous = ServerRosterReport.Evidence(lifecycleLog: "/tmp/s", lifecycleEntries: 1, usageLog: "/tmp/u", sessionsWithActivity: 2, callerIsNamed: false)
        let servers = Self.roster([Self.start(pid: 1500, secondsAgo: 90000)])
        let selection = ServerRoster.select(from: servers, pids: [1500], root: nil)

        #expect(ServerRosterReport.listing(servers, now: Self.now, evidence: anonymous).contains("does not name itself"))
        #expect(ServerRosterReport.plan(selection, now: Self.now, evidence: anonymous).contains("does not name itself"))
        #expect(ServerRosterReport.outcome(ServerRoster.stopAll(selection, stop: { _ in nil }), evidence: anonymous).contains("does not name itself"))
        #expect(!ServerRosterReport.listing(servers, now: Self.now, evidence: Self.evidence).contains("does not name itself"))
    }

    /// Every answer names the two files it was read from, and says when one of them yielded nothing.
    ///
    /// The usage log is the strongest guard input, and it can be pointed elsewhere or be unreadable. An answer that looked the same either way would let a caller read a confident plan whose best protection had quietly been switched off.
    @Test
    func everyAnswerNamesWhatItRead() {
        let servers = Self.roster([Self.start(pid: 1501, secondsAgo: 90000)])
        let blind = ServerRosterReport.Evidence(lifecycleLog: "/tmp/s.jsonl", lifecycleEntries: 1, usageLog: "/dev/null", sessionsWithActivity: 0, callerIsNamed: true)
        let text = ServerRosterReport.listing(servers, now: Self.now, evidence: blind)

        #expect(text.contains("read: /tmp/s.jsonl"))
        #expect(text.contains("signs of life: /dev/null"))
        #expect(text.contains("no answered call was readable there"))
        #expect(!ServerRosterReport.listing(servers, now: Self.now, evidence: Self.evidence).contains("no answered call was readable"))
    }

    /// A lifecycle log that yielded nothing is said on every face, because the roster is built from it alone.
    ///
    /// Otherwise `sift servers --file /nonexistent/server.jsonl` prints "none this machine believes are running" — word for word what a machine with nothing running prints. A mistyped path, an unreadable file and a clean machine would be one answer, which is the silent under-report every answer here is built not to give.
    @Test
    func anUnreadLifecycleLogIsSaidOnEveryFace() {
        let unread = ServerRosterReport.Evidence(
            lifecycleLog: "/nonexistent/server.jsonl",
            lifecycleEntries: 0,
            usageLog: "/tmp/u.jsonl",
            sessionsWithActivity: 2,
            callerIsNamed: true
        )
        let selection = ServerRoster.select(from: [], pids: [1502], root: nil)
        // The whole sentence, because its second half is the claim: an empty log is also what a machine that has never
        // started a server has, so it can say only that emptiness is not evidence — never that nothing was read.
        let caveat = "no server start or stop was readable in /nonexistent/server.jsonl, so an empty roster here does not show that nothing is running"

        #expect(ServerRosterReport.listing([], now: Self.now, evidence: unread).contains(caveat))
        #expect(ServerRosterReport.plan(selection, now: Self.now, evidence: unread).contains(caveat))
        #expect(ServerRosterReport.outcome(ServerRoster.stopAll(selection, stop: { _ in nil }), evidence: unread).contains(caveat))
        #expect(!ServerRosterReport.listing([], now: Self.now, evidence: Self.evidence).contains("no server start or stop was readable"))
    }

    /// Nothing running is a sentence rather than an empty answer.
    @Test
    func anEmptyRosterSaysSo() {
        #expect(ServerRosterReport.listing([], now: Self.now, evidence: Self.evidence).hasSuffix("mcp servers — none this machine believes are running"))
    }
}

extension ServerRosterTests {
    /// Records the pids a stop actually reached, from a closure that has to be `@Sendable`-safe by construction.
    final class Signalled: @unchecked Sendable {
        private let mutex = NSLock()
        private var seen: [Int32] = []

        var pids: [Int32] {
            mutex.lock()
            defer { mutex.unlock() }
            return seen
        }

        func record(_ pid: Int32) {
            mutex.lock()
            defer { mutex.unlock() }
            seen.append(pid)
        }
    }
}
