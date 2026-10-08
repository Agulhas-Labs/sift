//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A subagent's calls arrive under its parent's session id and are otherwise indistinguishable from its parent's, which would leave the whole of the subagent work this tool is judged on unattributable.
@Suite(.temporaryDirectories)
struct CallAttributionTests {
    private static func store(at instant: Date = Date(0)) throws -> (CallAttribution, URL) {
        let directory = try TemporaryDirectory.make("callers")
            .appendingPathComponent("callers")
        return (CallAttribution(directory: directory, now: { instant }), directory)
    }

    /// The server's own reading of a store's slips, on the same clock as ``store(at:)``'s default rather than the wall's.
    ///
    /// A call through a real server builds a cold index first, which on a loaded machine can outlast the claim window: on the wall's clock the slip would be stale by the time the server claims it, and the line would go out with no agent for a reason this suite is not about.
    private static func server(_ directory: URL) -> CallAttribution {
        CallAttribution(directory: directory, now: { Date(0) })
    }

    private static func payload(agent: String?, tool: String = "mcp__sift__digest", target: String = "Alpha") -> [String: Any] {
        var payload: [String: Any] = ["tool_name": tool, "tool_input": ["target": target]]
        if let agent {
            payload["agent_id"] = agent
        }
        return payload
    }

    /// The whole mechanism in one path: the hook sees the agent, the server sees the call, and the slip is what joins them.
    @Test
    func aSubagentsCallIsAttributedToTheSubagent() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: callers)

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "adae5f77")
    }

    /// A session's own call is not a subagent's, and the log must not say it is.
    @Test
    func theSessionsOwnCallIsNotAttributedToASubagent() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: nil), into: callers)

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == nil)
    }

    /// A parent's call writes a slip with no agent on it, so it claims one of its own rather than a subagent's, and the subagent's is left for the call that made it.
    @Test
    func aParentsCallClaimsItsOwnSlip() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: callers)
        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: nil, target: "Beta"), into: callers)

        #expect(callers.take(session: "s1", tool: "digest", target: "Beta") == nil)
        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "adae5f77")
    }

    /// Several contexts running under one session have calls in flight at once, and each keeps its own attribution.
    ///
    /// One slip per session was overwritten by the next context's hook run before the server could claim it, and the call went into the log naming no one.
    @Test
    func interleavedCallsFromTwoSubagentsAreEachAttributed() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "first"), into: callers)
        PreToolUseCommand.noteCaller(
            session: "s1",
            payload: Self.payload(agent: "second", tool: "mcp__sift__where", target: "Beta"),
            into: callers
        )

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "first")
        #expect(callers.take(session: "s1", tool: "where", target: "Beta") == "second")
    }

    /// Two contexts under one session can have calls in flight at once, so a slip is claimed only by the call it names — and left alone by every other, rather than consumed by the first to finish.
    @Test
    func aSlipIsClaimedOnlyByTheCallItNames() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: callers)

        #expect(callers.take(session: "s1", tool: "where", target: "Alpha") == nil)
        #expect(callers.take(session: "s1", tool: "digest", target: "Beta") == nil)
        #expect(callers.take(session: "s2", tool: "digest", target: "Alpha") == nil)
        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "adae5f77")
    }

    /// The documented limit, pinned so the claim and the code cannot drift apart.
    ///
    /// The tool and target are all there is to match on — nothing in a `tools/call` names the caller, and nothing shared between the hook run and the request could tell two `digest Alpha` calls apart. Two subagents making that call at once each leave a slip, claimed in the order the hook runs wrote them, which names each call's caller only where the calls are answered in that order. The aggregate stays a floor, which is what `usage` and `report` claim; a given line is not evidence about a given caller, which they do not.
    @Test
    func twoCallsOfOneShapeAreClaimedInTheOrderTheirHooksRan() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let later = CallAttribution(directory: directory, now: { Date(1) })

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "first"), into: callers)
        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "second"), into: later)

        #expect(later.take(session: "s1", tool: "digest", target: "Alpha") == "first")
        #expect(later.take(session: "s1", tool: "digest", target: "Alpha") == "second")
        #expect(later.take(session: "s1", tool: "digest", target: "Alpha") == nil)
    }

    /// Claimed once: a second call of the same shape is a different call and has its own hook run behind it.
    @Test
    func aSlipIsClaimedOnce() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: callers)

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "adae5f77")
        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == nil)
    }

    /// Claims made at once, from many threads, take every slip exactly once: no slip is claimed twice, and none is left behind while a claimant goes without.
    @Test
    func concurrentClaimsTakeEachSlipExactlyOnce() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let slips = 60
        for index in 0 ..< slips {
            PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "agent\(index)"), into: callers)
        }
        let claimed = Claimed()

        DispatchQueue.concurrentPerform(iterations: slips * 2) { _ in
            claimed.add(callers.take(session: "s1", tool: "digest", target: "Alpha"))
        }
        let agents = claimed.agents

        #expect(agents.count == slips)
        #expect(Set(agents).count == slips)
        #expect(Self.slips(of: "s1", in: directory).isEmpty)
    }

    /// A hook run whose call never happened — denied at the prompt, or interrupted — must not have its slip picked up by an unrelated call of the same shape much later.
    @Test
    func aStaleSlipIsNotClaimed() throws {
        let (writer, directory) = try Self.store(at: Date(0))
        defer { try? FileManager.default.removeItem(at: directory) }
        let later = CallAttribution(directory: directory, now: { Date(CallAttribution.claimWindow + 1) })

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: writer)

        #expect(later.take(session: "s1", tool: "digest", target: "Alpha") == nil)
    }

    /// A slip nobody claimed is forgotten, so the directory does not grow by a file per session forever.
    ///
    /// Unclaimed is the ordinary case, not the exceptional one: the server returns before it takes a slip whenever the call recorded no usage, and a hook run whose call never happened leaves one behind too. Past the claim window such a file can never be claimed anyway, so removing it removes nothing that was still live.
    @Test
    func aSlipNobodyClaimedIsForgottenOnceItCanNoLongerBeClaimed() throws {
        let (writer, directory) = try Self.store(at: Date(0))
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "abandoned", payload: Self.payload(agent: "adae5f77"), into: writer)
        let stale = try #require(Self.slips(of: "abandoned", in: directory).first)
        // Aged on the same clock the prune reads: a slip's age is its file's, and the fixture's clock is
        // not the filesystem's.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(-CallAttribution.claimWindow - 60)],
            ofItemAtPath: stale.path
        )

        // A later session's first call, which is where the listing is already paid for.
        let later = CallAttribution(directory: directory, now: { Date(0) })
        PreToolUseCommand.noteCaller(session: "live", payload: Self.payload(agent: "bbb"), into: later)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(Self.slips(of: "live", in: directory).count == 1)
        // And the live one is still claimable, which is the thing the prune must not cost.
        #expect(later.take(session: "live", tool: "digest", target: "Alpha") == "bbb")
    }

    /// The slip files one session has on disk.
    private static func slips(of session: String, in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("\(session).") }.map { directory.appendingPathComponent($0) }
    }

    /// A slip that goes stale after this session already has one is forgotten too, which a once-per-session rule could not do.
    ///
    /// Such a rule would prune only when a write created the session's first slip, and a session whose call is still in flight writing a second one would never prune — with something else's slip having gone stale in between.
    @Test
    func aSlipThatGoesStaleAfterThisSessionAlreadyHasOneIsForgottenToo() throws {
        let (writer, directory) = try Self.store(at: Date(0))
        defer { try? FileManager.default.removeItem(at: directory) }

        // This session's slip exists and is never claimed, so the next write is not its first.
        PreToolUseCommand.noteCaller(session: "live", payload: Self.payload(agent: "aaa"), into: writer)
        PreToolUseCommand.noteCaller(session: "abandoned", payload: Self.payload(agent: "bbb"), into: writer)
        let stale = try #require(Self.slips(of: "abandoned", in: directory).first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(-CallAttribution.claimWindow - 60)],
            ofItemAtPath: stale.path
        )

        PreToolUseCommand.noteCaller(session: "live", payload: Self.payload(agent: "ccc"), into: writer)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(Self.slips(of: "live", in: directory).count == 2)
    }

    /// The session id arrives in a hook payload, so it is untrusted input on a path — refused outright rather than sanitised, since two ids that sanitise alike would silently share a slip.
    @Test
    func aSessionIdThatIsNotANameIsRefusedRatherThanSanitised() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "../../escape", payload: Self.payload(agent: "adae5f77"), into: callers)

        #expect(callers.take(session: "../../escape", tool: "digest", target: "Alpha") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// A call to a server this is not — or to a tool it does not own — leaves no slip to be claimed by one that is.
    @Test
    func onlyThisServersToolsLeaveASlip() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(
            session: "s1",
            payload: Self.payload(agent: "adae5f77", tool: "Read"),
            into: callers
        )

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == nil)
    }

    /// What the hook actually does with an index call, exercised as one thing rather than as three pieces whose composition nothing covers.
    ///
    /// The composition is the part that can be dropped without any of the pieces failing: each of them has its own test, and a hook that called none of them would still pass every one.
    @Test
    func anIndexCallIsRecorded_ItsCallerNamed_AndItsRootPinned() throws {
        let root = try MCPTestRepo.make()
        let (callers, directory) = try Self.store(at: Date())
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerDirectory = try TemporaryDirectory.make("ledger")
            .appendingPathComponent("ledger")
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }

        let printed = PreToolUseCommand.adviceTaken(
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "adae5f77"),
            payload: Self.payload(agent: "adae5f77"),
            cwd: root.path,
            ledger: AdviceLedger(directory: ledgerDirectory),
            callers: callers
        )
        let envelope = try #require(printed)
        let object = try #require(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let input = try #require(specific["updatedInput"] as? [String: Any])

        #expect(callers.take(session: "s1", tool: "digest", target: "Alpha") == "adae5f77")
        #expect(CanonicalPath.of(input["root"] as? String ?? "") == CanonicalPath.of(root.path))
        #expect(input["target"] as? String == "Alpha")
    }

    /// The end of the path: a line in `usage.jsonl` that names the subagent that earned it.
    @Test
    func aLoggedCallCarriesTheSubagentThatMadeIt() async throws {
        let root = try MCPTestRepo.make()
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage.jsonl")
        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "adae5f77"), into: callers)

        let lines = try await Self.callDigest(
            on: root,
            logging: log,
            callers: Self.server(directory),
            session: "s1"
        )
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(entry["agent"] as? String == "adae5f77")
        #expect(UsageScan.Entry(line: Data(lines[0].utf8))?.agent == "adae5f77")
    }

    /// The reported symptom, end to end: another context's hook run lands between this context's and the server's answer, and the log line still names this context — the field a whole read of the file it digested is let through on (`DigestedFiles`).
    @Test
    func aCallAnsweredAfterAnotherContextsHookRunStillCarriesItsCaller() async throws {
        let root = try MCPTestRepo.make()
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage.jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        PreToolUseCommand.noteCaller(session: "s1", payload: Self.payload(agent: "reader"), into: callers)
        PreToolUseCommand.noteCaller(
            session: "s1",
            payload: Self.payload(agent: "other", tool: "mcp__sift__where", target: "Beta"),
            into: callers
        )

        let lines = try await Self.callDigest(
            on: root,
            logging: log,
            callers: Self.server(directory),
            session: "s1"
        )
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(entry["agent"] as? String == "reader")
    }

    /// Nothing here is load-bearing: with no hook to leave a slip, the line is exactly the line this log has always written, and every reader of it is unchanged.
    @Test
    func aCallNoHookSawIsLoggedExactlyAsBefore() async throws {
        let root = try MCPTestRepo.make()
        let (_, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage.jsonl")

        let lines = try await Self.callDigest(
            on: root,
            logging: log,
            callers: Self.server(directory),
            session: "s1"
        )
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(entry["agent"] == nil)
        #expect(entry["tool"] as? String == "digest")
        #expect(UsageScan.Entry(line: Data(lines[0].utf8))?.agent == nil)
    }

    private static func callDigest(on root: URL, logging log: URL, callers: CallAttribution, session: String) async throws -> [Substring] {
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            usage: UsageLog(fileURL: log),
            callers: callers,
            session: session
        )
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": "Alpha"]],
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try toServer.fileHandleForWriting.write(contentsOf: data)
        _ = await responses.next()
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    }
}

private extension CallAttributionTests {
    /// The agents concurrent claims came back with, collected under a lock.
    final class Claimed: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [String] = []

        var agents: [String] {
            lock.withLock { collected }
        }

        func add(_ agent: String?) {
            guard let agent else { return }
            lock.withLock { collected.append(agent) }
        }
    }
}

private extension Date {
    init(_ epochSeconds: TimeInterval) {
        self.init(timeIntervalSince1970: 1_760_000_000 + epochSeconds)
    }
}
