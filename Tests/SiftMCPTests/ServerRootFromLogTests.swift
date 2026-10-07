//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `sift pre-tool-use`, driven through the built binary, deciding whether a rootless index call needs its caller's root from the server lifecycle log: left alone only where this session's live server, as the log records it, already answers from the caller's tree.
///
/// Every log here is a scratch file the child reads through `SIFT_SERVER_LOG`, and a live server is this test process itself, recorded with its own pid and launch time, so nothing depends on the servers running on the machine. The start lines driven through the binary name no parent, as lines written before servers recorded one do, so they reach the session lookup that remains for them; the lookup by the hook's ancestry is ``ServerRootByParentTests``, and the injected cases below pin its rules.
@Suite(.temporaryDirectories)
struct ServerRootFromLogTests {
    private static var session: String {
        "server-root-session"
    }

    /// The normal case: the session's own server is live and launched in the caller's repository, so naming the root would change nothing.
    @Test
    func aLiveServerOfTheSessionInTheCallersTreeDrawsNoOutput() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [.live(session: Self.session, root: repo.path)])

        let run = try Self.run(payload: Self.payload(cwd: repo.appendingPathComponent("Sources/App").path), serverLog: log)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A project directory in the environment is not where the server is: with nothing on record for the session the call is pinned, which is the case of a hook that inherited a stale one.
    @Test
    func aProjectDirectoryWithNoServerOnRecordIsPinned() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [])

        let run = try Self.run(payload: Self.payload(cwd: repo.path), serverLog: log, projectDirectory: repo.path)

        try Self.expectPinned(run, to: repo.path)
    }

    /// A subagent's payload names its parent's session, and the subagent shares the parent's server, so the parent's server root decides.
    @Test
    func aSubagentIsComparedWithItsParentsServer() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [.live(session: Self.session, root: repo.path)])
        var payload = Self.payload(cwd: repo.path)
        payload["agent_id"] = "subagent-1"

        let run = try Self.run(payload: payload, serverLog: log)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A start line whose pid is no longer the process that wrote it, whether that process has exited or the pid was handed on, says nothing about a server now.
    @Test(arguments: [false, true])
    func aServerThatIsNoLongerRunningIsNoEvidence(exited: Bool) throws {
        let repo = try MCPTestRepo.make()
        let recorded: RecordedStart = exited
            ? try .exited(session: Self.session, root: repo.path)
            : .reused(session: Self.session, root: repo.path)
        let log = try Self.log(recording: [recorded])

        let run = try Self.run(payload: Self.payload(cwd: repo.path), serverLog: log)

        try Self.expectPinned(run, to: repo.path)
    }

    /// Another conversation's live server in the caller's tree is not the one answering this call.
    @Test
    func anotherSessionsLiveServerIsNoEvidence() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [.live(session: "another-session", root: repo.path)])

        let run = try Self.run(payload: Self.payload(cwd: repo.path), serverLog: log)

        try Self.expectPinned(run, to: repo.path)
    }

    /// The newest live start under the session decides: an older live one elsewhere is passed over, and so is a newer one whose process has gone.
    @Test
    func theNewestLiveStartOfTheSessionDecides() throws {
        let repo = try MCPTestRepo.make()
        let other = try MCPTestRepo.make(declaring: "Beta")
        let log = try Self.log(recording: [
            .live(session: Self.session, root: other.path),
            .live(session: Self.session, root: repo.path),
            .reused(session: Self.session, root: other.path),
        ])

        let run = try Self.run(payload: Self.payload(cwd: repo.path), serverLog: log)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// The lookup is the same under another harness: a Cursor call whose session's live server is on record in the caller's tree is left alone.
    @Test
    func anotherHarnessReadsTheSameRecord() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [.live(session: "cursor-session", root: repo.path)])
        let payload: [String: Any] = [
            "conversation_id": "c1", "generation_id": "g1", "model": "default", "tool_name": "MCP:digest",
            "tool_input": ["target": "Alpha"], "tool_use_id": "t1", "cwd": "", "session_id": "cursor-session",
            "hook_event_name": "preToolUse", "cursor_version": "1.0", "workspace_roots": [repo.path],
        ]

        let run = try Self.run(payload: payload, serverLog: log, agent: "cursor")

        #expect(run.status == 0)
        #expect(!run.printed.contains("updated_input"), "printed \(run.printed)")
    }

    /// A payload with no session names no server, even where a live start was recorded under the placeholder the ledger falls back to.
    @Test
    func aPayloadWithNoSessionIsPinned() throws {
        let repo = try MCPTestRepo.make()
        let log = try Self.log(recording: [.live(session: "unknown", root: repo.path)])
        var payload = Self.payload(cwd: repo.path)
        payload["session_id"] = nil

        let run = try Self.run(payload: payload, serverLog: log)

        try Self.expectPinned(run, to: repo.path)
    }

    /// Pid 1 is everyone's ancestor, so a live server recorded as its child says nothing about who spawned the hook.
    @Test
    func aServerWhoseParentIsLaunchdIsNoAncestorsServer() {
        let entries = [Self.entry(pid: 900, parent: 1, root: "/repo/launchd")]

        #expect(CallerRoot.serverDirectory(ancestors: [500, 1], session: nil, among: entries) { _ in true } == nil)
    }

    /// The closest ancestor with a live server decides, ahead of a newer line under a farther ancestor, and a line whose server is gone is passed over for an older live one.
    @Test
    func theClosestAncestorWithALiveServerDecides() {
        let entries = [
            Self.entry(pid: 901, parent: 500, root: "/repo/closest-older"),
            Self.entry(pid: 902, parent: 500, root: "/repo/closest-gone"),
            Self.entry(pid: 903, parent: 600, root: "/repo/farther-newer"),
        ]

        let found = CallerRoot.serverDirectory(ancestors: [500, 600], session: nil, among: entries) { $0.pid != 902 }

        #expect(found == "/repo/closest-older")
    }

    /// Two live servers under one ancestor in different trees leave the call amended, since nothing says which of them answers; two in the same tree still name it.
    @Test(arguments: [false, true])
    func anAncestorsLiveServersInDifferentTreesNameNoDirectory(sameTree: Bool) {
        let entries = [
            Self.entry(pid: 905, parent: 500, root: "/repo/harness"),
            Self.entry(pid: 906, parent: 500, root: sameTree ? "/repo/harness" : "/repo/execd"),
        ]

        let found = CallerRoot.serverDirectory(ancestors: [500], session: nil, among: entries) { _ in true }

        #expect(found == (sameTree ? "/repo/harness" : nil))
    }

    /// The session reaches only a line that names no parent: one naming a parent outside the hook's ancestry was started by some other process.
    @Test(arguments: [false, true])
    func theSessionReachesOnlyALineThatNamesNoParent(namesParent: Bool) {
        let entries = [Self.entry(pid: 904, parent: namesParent ? 777 : nil, root: "/repo/session", session: "s1")]

        let found = CallerRoot.serverDirectory(ancestors: [500], session: "s1", among: entries) { _ in true }

        #expect(found == (namesParent ? nil : "/repo/session"))
    }

    /// The walk up from a pid through shells stops before pid 1, at a repeat, and at its depth.
    @Test
    func theAncestryWalkStopsBeforeLaunchdAtARepeatAndAtItsDepth() {
        let chain: [Int32: Int32] = [10: 20, 20: 30, 30: 1]
        let cycle: [Int32: Int32] = [10: 20, 20: 30, 30: 20]
        let long: [Int32: Int32] = [10: 11, 11: 12, 12: 13, 13: 14, 14: 15, 15: 16]
        let shell: (Int32) -> String? = { _ in "zsh" }

        #expect(CallerRoot.ancestors(of: 10, parent: { chain[$0] }, name: shell) == [20, 30])
        #expect(CallerRoot.ancestors(of: 10, parent: { cycle[$0] }, name: shell) == [20, 30])
        #expect(CallerRoot.ancestors(of: 10, parent: { long[$0] }, name: shell) == [11, 12, 13, 14])
    }

    /// A server that is running is serving only while it is still the child of the parent its line names, which keeps a reused parent pid from vouching for an orphan.
    @Test
    func aServerServesOnlyWhileItIsStillItsParentsChild() {
        let launched = ServerLifecycleReport.startTime(of: getpid()) ?? Date()
        let stamp = ServerLifecycleLog.stamp(launched)
        let ownParent = ServerLifecycleEntry(event: "start", pid: getpid(), stamp: stamp, root: "/repo", parent: getppid())
        let otherParent = ServerLifecycleEntry(event: "start", pid: getpid(), stamp: stamp, root: "/repo", parent: getpid())

        #expect(CallerRoot.isServing(ownParent))
        #expect(!CallerRoot.isServing(otherParent))
    }

    /// A start line for the injected lookups, launched at a fixed time.
    static func entry(pid: Int32, parent: Int32?, root: String, session: String? = nil) -> ServerLifecycleEntry {
        ServerLifecycleEntry(event: "start", pid: pid, stamp: "2026-10-06T12:00:00Z", root: root, session: session, parent: parent)
    }

    /// Asserts that `run` printed the rootless digest back with its root set to `root` and its target untouched.
    static func expectPinned(_ run: (status: Int32, printed: String), to root: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(run.printed.utf8)) as? [String: Any],
            "printed \(run.printed)",
            sourceLocation: sourceLocation
        )
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
        let amended = try #require(specific["updatedInput"] as? [String: String], sourceLocation: sourceLocation)

        #expect(run.status == 0, sourceLocation: sourceLocation)
        #expect(amended["root"].map(CanonicalPath.of) == CanonicalPath.of(root), sourceLocation: sourceLocation)
        #expect(amended["target"] == "Alpha", sourceLocation: sourceLocation)
    }

    /// A rootless digest of `Alpha` from `cwd`, under this suite's session.
    static func payload(cwd: String, session: String = session) -> [String: Any] {
        [
            "session_id": session, "cwd": cwd, "hook_event_name": "PreToolUse",
            "tool_name": "mcp__sift__digest", "tool_input": ["target": "Alpha"], "tool_use_id": "t1",
        ]
    }

    /// A scratch lifecycle log holding a start line for each of `starts`, oldest first.
    static func log(recording starts: [RecordedStart], sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let directory = try TemporaryDirectory.make("server-log", sourceLocation: sourceLocation)
        let file = directory.appendingPathComponent("server.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let log = ServerLifecycleLog(fileURL: file)
        for start in starts {
            log.recordStart(pid: start.pid, session: start.session, root: start.root, now: start.launched)
        }
        return file
    }

    /// Runs this build's `sift pre-tool-use` on `payload`, reading the log file given as the lifecycle log and the project directory given as `CLAUDE_PROJECT_DIR` (unset where none is): its exit status and what it printed.
    ///
    /// The child gets a home, advice directory, usage log and empty Claude Code configuration of its own, and no `GIT_` variable, so neither the user's state nor a git hook running the suite reaches it.
    static func run(
        payload: [String: Any],
        serverLog: URL,
        projectDirectory: String? = nil,
        agent: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (status: Int32, printed: String) {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        let home = try TemporaryDirectory.make("server-root-home", sourceLocation: sourceLocation)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["pre-tool-use"] + (agent.map { ["--agent", $0] } ?? [])
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["CFFIXED_USER_HOME"] = home.path
        environment["SIFT_HOME"] = home.appendingPathComponent("sift").path
        environment["SIFT_SERVER_LOG"] = serverLog.path
        environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
        environment["SIFT_NO_ADVICE"] = nil
        environment["CLAUDE_CODE_SESSION_ID"] = nil
        environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("claude").path
        environment["CLAUDE_PROJECT_DIR"] = projectDirectory
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        input.fileHandleForWriting.closeFile()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")
    }
}

extension ServerRootFromLogTests {
    /// One start line for a scratch lifecycle log: the pid, the session and directory it names, and when it says the server launched.
    struct RecordedStart {
        let pid: Int32
        let session: String
        let root: String
        let launched: Date

        /// A server that is running: this test process, at the moment the kernel says it launched.
        static func live(session: String, root: String) -> RecordedStart {
            RecordedStart(pid: getpid(), session: session, root: root, launched: ServerLifecycleReport.startTime(of: getpid()) ?? Date())
        }

        /// A pid since handed to another process: this one's, with a launch an hour before the real one.
        static func reused(session: String, root: String) -> RecordedStart {
            let launched = (ServerLifecycleReport.startTime(of: getpid()) ?? Date()).addingTimeInterval(-3600)
            return RecordedStart(pid: getpid(), session: session, root: root, launched: launched)
        }

        /// A server that has exited: a process run to its end and reaped before the line is read.
        static func exited(session: String, root: String) throws -> RecordedStart {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            let launched = Date()
            try process.run()
            process.waitUntilExit()
            return RecordedStart(pid: process.processIdentifier, session: session, root: root, launched: launched)
        }
    }
}
