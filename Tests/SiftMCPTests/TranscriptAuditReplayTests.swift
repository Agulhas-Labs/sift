//
// Copyright © Agulhas Labs
//

import Foundation
import os
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay`: a transcript's cold lookups put to the hook as it stands now, counted by what it would do with each.
@Suite(.temporaryDirectories)
struct TranscriptAuditReplayTests {
    /// One call on a line of its own, as the harness writes it, with the session, directory and time it carries.
    static func call(_ command: String, id: String, cwd: String, at stamp: String) throws -> Data {
        try use("Bash", input: ["command": command], id: id, cwd: cwd, at: stamp)
    }

    /// One call of any tool on a line of its own, as ``call(_:id:cwd:at:)`` writes a Bash one.
    static func use(_ tool: String, input: [String: Any], id: String, cwd: String, at stamp: String) throws -> Data {
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": cwd,
            "timestamp": stamp,
            "message": ["id": "m-\(id)", "content": [["type": "tool_use", "id": id, "name": tool, "input": input]]],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The section for `lines` written as one session's transcript, replayed with the real hook and no window, its answerer held to the roomy time budget so a loaded machine cannot withhold an answer `overTime` and, through the back-off that overrun notes, every later answer of its shape.
    private static func replayed(_ lines: [Data], roots: RootDiscovery = RootDiscovery()) async throws -> [String] {
        let hook = try HookReplay(
            directory: TemporaryDirectory.make("hook-replay"),
            timeBudget: InPlaceAnswerTests.roomy,
            roots: roots
        )
        return try await replayed(lines, hook: hook)
    }

    /// `AuditCommand.replaySection` over `transcript` as `audit --replay` runs it, under the roomy time budget and on a thread of its own, for the reason ``replayed(_:hook:)`` gives.
    static func replaySection(of transcript: URL, since: Date? = nil, until: Date? = nil) async throws -> [String] {
        let scratch = try TemporaryDirectory.make("replay")
        return try await InPlaceAnswerTests.onItsOwnThread {
            Result {
                try AuditCommand.replaySection(
                    projectsDirectory: transcript.deletingLastPathComponent(),
                    since: since,
                    until: until,
                    transcript: transcript.path,
                    scratch: scratch,
                    timeBudget: InPlaceAnswerTests.roomy
                )
            }
        }.get()
    }

    /// The section for `lines`, replayed against `hook` rather than one `replaySection` builds itself — so a test can drive a `HookReplay` of its own size budget.
    ///
    /// Replayed on a thread of its own, as ``InPlaceAnswerTests/answer(_:from:serverGone:wholeCommand:timeBudget:sizeBudget:backoff:)`` answers: the answerer blocks its caller while the concurrency pool computes the answer, and a suite of replays blocking the pool's own threads starved it until every answer in flight ran out of time together.
    private static func replayed(_ lines: [Data], hook: HookReplay) async throws -> [String] {
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        return await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.section(
                projectsDirectory: transcript.deletingLastPathComponent(),
                since: nil,
                transcript: transcript.path,
                hook: hook
            )
        }
    }

    /// A whole `cat` of a file the hook answers in place today is recovered, a cold `sed` window of another is recovered too, and the share is recomputed from both.
    @Test func aWholeReadAndAColdWindowAreBothRecovered() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 80))\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            Self.call("sed -n 1,200p Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  cold            2  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       2  the hook would now answer these in place"), "\(section)")
        #expect(section.contains("         2  ShellAdvice → digest"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  unreplayable    0  ") }, "\(section)")
        #expect(section.contains("  replayed share 100% = (indexed 0 + recovered 2) / 2 — the audit's own 0% — on the old denominator 100% = … / 2 (text searches in one file +0, unreplayable +0, not worth +0)"), "\(section)")
    }

    /// A context straddling `--since` is judged from its first line: the pre-window grep is answered in place by the real hook, so its identical re-run inside the window finds the denial already on record and is let through by the ledger's own re-run rule — still cold, never recovered — rather than answered afresh.
    @Test func aStraddlingContextIsJudgedFromItsFirstCallSoTheInWindowRerunStaysCold() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let grep = "grep -n 'func stock1()' Sources/App/Depot.swift"

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call(grep, id: "b1", cwd: root.path, at: "2026-09-20T09:59:00Z"),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "9:    func stock1() -> Int {"),
            Self.call(grep, id: "b2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "b2", isError: false, text: "9:    func stock1() -> Int {"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript, since: ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       0  the hook would now answer these in place"), "\(section)")
        #expect(section.contains("         1  ledger"), "\(section)")
        #expect(section.contains("  replayed share 0% = (indexed 0 + recovered 0) / 1 — the audit's own 0% — on the old denominator 0% = … / 1 (text searches in one file +0, unreplayable +0, not worth +0)"), "\(section)")
    }

    /// `--until` cuts the same way `--since` does: a context straddling it counts only its in-window call — the identical re-run after `--until` is outside the window and dropped rather than counted a second time.
    @Test func aStraddlingContextsCallAfterUntilIsNotCounted() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let grep = "grep -n 'func stock1()' Sources/App/Depot.swift"

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call(grep, id: "b1", cwd: root.path, at: "2026-09-20T09:59:00Z"),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "9:    func stock1() -> Int {"),
            Self.call(grep, id: "b2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "b2", isError: false, text: "9:    func stock1() -> Int {"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript, until: ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains("  replayed share 100% = (indexed 0 + recovered 1) / 1 — the audit's own 0% — on the old denominator 100% = … / 1 (text searches in one file +0, unreplayable +0, not worth +0)"), "\(section)")
    }

    /// A `Read` of a file under a gone worktree is replayed against the repository above it even where the session's own cwd was never the worktree — mapped by the path the call names, not by the cwd it ran from.
    @Test func aWorktreePathIsMappedWhateverTheCWDIs() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let worktreePath = root.appendingPathComponent(".claude/worktrees/gone/Sources/App/Depot.swift").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": root.path,
            "timestamp": "2026-09-20T10:00:00Z",
            "message": ["id": "m-r1", "content": [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": worktreePath]]]],
        ]
        let lines = try [
            JSONSerialization.data(withJSONObject: object),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    0  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains { $0.hasPrefix("         1  ") && $0.hasSuffix("→ digest") }, "\(section)")
    }

    /// A command that moves into a worktree gone from disk, from a directory outside it, is replayed against the repository above that worktree, as a call made inside one is — not withheld as a path in no repository.
    @Test func aCdIntoAGoneWorktreeIsReplayedAgainstItsRepository() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let gone = root.appendingPathComponent(".claude/worktrees/agent-gone").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("cd \(gone) && cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
    }

    /// A command that opens by moving into a directory gone from disk, one no worktree mapping reaches, is unreplayable — never judged from the cwd it left, where it would read as a lookup in no repository.
    @Test func aCdIntoADirectoryGoneFromDiskIsUnreplayable() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let gone = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-gone").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("cd \(gone) && cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    1  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains("  recovered       0  the hook would now answer these in place"), "\(section)")
    }

    /// A `Read` of a file whose absolute path sits in a directory gone from disk — a sibling clone since deleted — is unreplayable: nothing about the call's own cwd says so, since the cwd it ran from still exists.
    @Test func aReadOfAFileWhoseDirectoryIsGoneIsUnreplayable() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let gone = root.deletingLastPathComponent().appendingPathComponent("gone-clone/Sources/App/Depot.swift").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let object: [String: Any] = [
            "type": "assistant",
            "sessionId": "replayed-session",
            "cwd": root.path,
            "timestamp": "2026-09-20T10:00:00Z",
            "message": ["id": "m-r1", "content": [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": gone]]]],
        ]
        let lines = try [
            JSONSerialization.data(withJSONObject: object),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    1  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains("  recovered       0  the hook would now answer these in place"), "\(section)")
    }

    /// `HookReplay`'s size budget drives the real in-place answerer, not a fixture: a whole read the live hook answers comfortably under its own ten-thousand-byte budget is measured over-size once the replay's own budget is set below it, and the bytes it names are the answer the answerer actually built.
    @Test func theReplaysSizeBudgetDrivesTheRealAnswererOversize() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), sizeBudget: 10, timeBudget: InPlaceAnswerTests.roomy)
        let verdict = await Self.verdict(of: "cat Sources/App/Depot.swift", cwd: root.path, hook: hook)

        #expect(verdict?.rule == InPlaceAnswerer.Withholding.overSize.rawValue, "\(String(describing: verdict))")
        let answerBytes = try #require(verdict?.answerBytes)
        #expect(answerBytes > 10, "the measured size should be the real answer the answerer built, not a fixture: \(answerBytes)")
    }

    /// A window of a file an earlier cold `cat` of it was recovered for is the located read of the world the replay models, guided and out of the share, and a whole `Read` of a file a recovered window's members answer only located is recovered in its turn, that answer being no digest of the file — never still cold.
    @Test func aReadOfAFileOnlyARecoveredAnswerLocatedIsScoredAsALocatedRead() async throws {
        let root = try await WorthAnsweringFixture.repository()
        // Bodies long enough that the file's digest is smaller than a window of nearly all of it, and its members smaller still, so they answer the window.
        // The window stops short of the last lines: one over every line is the whole read, answered with the file's digest.
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\(WorthAnsweringFixture.comment)\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let gizmo = root.appendingPathComponent("Sources/App/Gizmo.swift").path

        let section = try await Self.replayed([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            Self.call("sed -n 10,20p Sources/App/Depot.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func stock2"),
            Self.call("sed -n 1,240p Sources/App/Gizmo.swift", id: "c3", cwd: root.path, at: "2026-09-20T10:02:00Z"),
            TranscriptFixture.toolResult(id: "c3", isError: false, text: "struct Gizmo"),
            Self.use("Read", input: ["file_path": gizmo], id: "c4", cwd: root.path, at: "2026-09-20T10:03:00Z"),
            TranscriptFixture.toolResult(id: "c4", isError: false, text: "struct Gizmo"),
        ])

        #expect(section.contains("  cold            4  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       3  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  located         1  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  read whole      0  ") }, "\(section)")
        #expect(section.contains("  replayed share 100% = (indexed 0 + recovered 3) / 3 — the audit's own 0% — on the old denominator 100% = … / 3 (text searches in one file +0, unreplayable +0, not worth +0)"), "\(section)")
    }

    /// A window of a file the context's own digest call named stays still cold where the scan counts it cold: the call failed, so the scan credits nothing, while the hook holds the digest from the moment the call was made — a real digest, not one the replay answered.
    @Test func aWindowAfterTheContextsOwnDigestCallStaysStillCold() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let section = try await Self.replayed([
            Self.use("mcp__sift__digest", input: ["target": "Sources/App/Depot.swift"], id: "d1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "d1", isError: true, text: "the store is busy"),
            Self.call("sed -n 10,20p Sources/App/Depot.swift", id: "d2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "d2", isError: false, text: "func stock2"),
        ])

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      1  ") }, "\(section)")
        #expect(section.contains("         1  noLookup"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  located         0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  read whole      0  ") }, "\(section)")
    }

    /// A `cd` inside the command moves where its relative window is read from, so a recovered answer of the file the line's own (pre-`cd`) directory would name must not move this row to `located` — it stays still cold, and the share reads 1/2, not 1/1.
    ///
    /// `CdRelocationHook` stands in for the real hook so the row's fate turns only on the replay's own relocation guard, never on repository resolution or the compression floor.
    @Test func aWindowBehindACdIsNotMovedByAnAnswerOfTheCWDsFile() throws {
        let root = try TemporaryDirectory.make("root")
        let other = try TemporaryDirectory.make("other")
        let hook = CdRelocationHook(locatedPath: root.appendingPathComponent("Sources/App/Gizmo.swift").path)

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("cat Sources/App/Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Gizmo"),
            Self.call("cd \(other.path) && sed -n 10,20p Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let probes = ReplayProbes(since: nil, until: nil, timeZone: .current, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, memberExists: { _, _, _ in true })
        let context = TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: hook)
        let section = TranscriptReplay.render([context], unredacted: true)

        #expect(section.contains { $0.hasPrefix("  located         0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      1  ") }, "\(section)")
        #expect(section.contains("  replayed share 50% = (indexed 0 + recovered 1) / 2 — the audit's own 0% — on the old denominator 50% = … / 2 (text searches in one file +0, unreplayable +0, not worth +0)"), "\(section)")
    }

    /// A window behind a `cd` into the repository, of a file an earlier window behind the same `cd` already showed, is a re-read at the scan itself: both relative paths are spelled out against the directory the `cd` moves to, which is where the hook reads them from, so the second is neither cold nor left still cold as `noLookup`.
    @Test func aWindowBehindACdOfAFileAnEarlierWindowBehindTheSameCdAlreadyShowedIsARescanReRead() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 80))\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let elsewhere = try TemporaryDirectory.make("elsewhere")

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.call("cd \(root.path) && sed -n 1,9999p Sources/App/Gizmo.swift", id: "c1", cwd: elsewhere.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Gizmo"),
            Self.call("cd \(root.path) && sed -n 100,120p Sources/App/Gizmo.swift", id: "c2", cwd: elsewhere.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func part25"),
        ], hook: hook)

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
    }

    /// A cold window over the size budget is recovered with a bounded answer — the digest lines of only the members it overlaps, because the file's whole digest would not fit — and that answer's line-range target locates the file for a later window on it exactly as a whole digest would: the second window is scored `located`, not still cold.
    ///
    /// The first window runs behind a `cd` and in front of a `||` fallback that moves again, which the hook answers in place — the fallback runs only where the window fails — and the scan does not place, so it never opens the file; the second window, by its absolute path, is a genuine first touch of it, and the only thing that can excuse it is the hook's own record of the first answer.
    @Test func aWindowAfterABoundedAnswerIsLocated() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // Each body line is padded, so what the bounded answer saves on the first window clears the floor a window whose lines it does not show is held to.
        let padding = " // " + String(repeating: "x", count: 250)
        let members = (1 ... 80).map { "    func part\($0)() -> Int {\n        let count = \($0)\(padding)\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), sizeBudget: 1500, timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.call("cd Sources/App && sed -n 1,80p Gizmo.swift || cd ..", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func part1"),
            Self.call("sed -n 200,205p \(root.path)/Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func part49"),
        ], hook: hook)

        #expect(section.contains("  cold            2  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  located         1  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
    }

    /// The same bounded first window, but the second call is a whole `cat` of the file rather than a window: the bounded answer only excuses a later window, never a whole read, so the whole read is never counted `located`.
    @Test func aWholeReadAfterABoundedAnswerIsNotLocated() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 80).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), sizeBudget: 1500, timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.call("cd Sources/App && sed -n 1,80p Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func part1"),
            Self.call("cat Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ], hook: hook)

        #expect(section.contains { $0.hasPrefix("  located         0  ") }, "\(section)")
    }

    /// A replay of many calls from one working directory asks git for each directory's root once in the whole run, however many times the hook's code asks for it, and still answers every call from the root git named.
    @Test func aReplayDiscoversEachDirectorysRootOnce() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let tally = DiscoveryTally()
        let hook = try HookReplay(
            directory: TemporaryDirectory.make("hook-replay"),
            timeBudget: InPlaceAnswerTests.roomy,
            roots: RootDiscovery { directory in
                tally.note(directory)
                return GitContext.spawnedRoot(from: directory)
            }
        )
        let lines = try (1 ... 4).flatMap { round in
            try [
                Self.call("cat Sources/App/Depot.swift", id: "c\(round)", cwd: root.path, at: "2026-09-20T10:0\(round):00Z"),
                TranscriptFixture.toolResult(id: "c\(round)", isError: false, text: "struct Depot"),
                Self.call("sed -n 1,3p Sources/App/Depot.swift", id: "w\(round)", cwd: root.path, at: "2026-09-20T10:0\(round):10Z"),
                TranscriptFixture.toolResult(id: "w\(round)", isError: false, text: "struct Depot"),
                Self.use("mcp__sift__digest", input: ["target": "Depot"], id: "d\(round)", cwd: root.path, at: "2026-09-20T10:0\(round):20Z"),
                TranscriptFixture.toolResult(id: "d\(round)", isError: false, text: "struct Depot"),
            ]
        }
        let section = try await Self.replayed(lines, hook: hook)
        let asked = tally.asked

        #expect(asked[root.path] == 1, "\(asked)")
        #expect(asked.values.allSatisfy { $0 == 1 }, "\(asked)")
        #expect(section.contains { $0.hasPrefix("  recovered       ") && !$0.hasPrefix("  recovered       0") }, "\(section)")
        // The computed answer's own engine opens against the canonical root — a second, distinct key from the
        // classification directories above — and asks for it exactly once too: only true when the detached
        // compute carries the bound discovery across itself, rather than spawning git unbound.
        #expect(asked[CanonicalPath.of(root.path)] == 1, "\(asked)")
    }

    /// A `Read` of a file below the floor under a gone worktree is put to the floor at the repository the hook is handed, not at the path as written, which is gone and so could never be excused.
    @Test func aBelowFloorReadUnderAGoneWorktreeIsNotCold() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try "/// A tiny type.\nstruct Tiny {\n    let count = 1\n}\n"
            .write(to: root.appendingPathComponent("Sources/App/Tiny.swift"), atomically: true, encoding: .utf8)
        let worktreePath = root.appendingPathComponent(".claude/worktrees/gone/Sources/App/Tiny.swift").path

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.use("Read", input: ["file_path": worktreePath], id: "r1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Tiny"),
        ], hook: hook)

        #expect(section.contains("  cold            0  the lookups the audit calls cold"), "\(section)")
    }

    /// The suite's own replays wait out an answer slower than the live hook's time budget: the answer's engine is held past that budget where it asks for its root, and the whole read is still recovered rather than withheld `overTime`, which is what a loaded machine did to the first answer and, through the back-off, to every later one of its shape.
    @Test func aReplayInThisSuiteWaitsOutAnAnswerSlowerThanTheLiveBudget() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let canonical = CanonicalPath.of(root.path)
        try #require(canonical != root.path, "the answer's engine must ask for a root the classification has not already asked for")
        let slow = RootDiscovery { directory in
            if directory.path == canonical {
                Thread.sleep(forTimeInterval: InPlaceAnswer.timeBudget + 1)
            }
            return GitContext.spawnedRoot(from: directory)
        }

        let section = try await Self.replayed([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ], roots: slow)

        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(!section.contains { $0.contains("overTime") }, "\(section)")
    }

    /// The suite's replays run off the concurrency pool: every root the replay itself asks for is asked on a thread outside it, so a suite of replays blocked on their answers can never hold every one of the pool's threads the answers themselves need, which under load starved the pool until every answer in flight was withheld `overTime` at once.
    @Test func aReplayInThisSuiteBlocksNoThreadOfTheConcurrencyPool() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let canonical = CanonicalPath.of(root.path)
        let queues = OSAllocatedUnfairLock(initialState: [String]())
        let probed = RootDiscovery { directory in
            // The answer's own engine asks for the canonical root from the pool, where it belongs; the replay asks for the rest.
            if directory.path != canonical {
                let label = String(cString: __dispatch_queue_get_label(nil))
                queues.withLock { $0.append(label) }
            }
            return GitContext.spawnedRoot(from: directory)
        }

        _ = try await Self.replayed([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ], roots: probed)
        let asked = queues.withLock { $0 }

        #expect(!asked.isEmpty)
        #expect(!asked.contains { $0.hasSuffix(".cooperative") }, "\(asked)")
    }

    /// A single call this suite judges outside a replay is judged off the concurrency pool too, for the same reason: the size-budget test once asked the hook straight from its own pool thread, and under load it was withheld `overTime` rather than over-size.
    @Test func aVerdictInThisSuiteBlocksNoThreadOfTheConcurrencyPool() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let canonical = CanonicalPath.of(root.path)
        let queues = OSAllocatedUnfairLock(initialState: [String]())
        let probed = RootDiscovery { directory in
            if directory.path != canonical {
                let label = String(cString: __dispatch_queue_get_label(nil))
                queues.withLock { $0.append(label) }
            }
            return GitContext.spawnedRoot(from: directory)
        }
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy, roots: probed)

        _ = await Self.verdict(of: "cat Sources/App/Depot.swift", cwd: root.path, hook: hook)
        let asked = queues.withLock { $0 }

        #expect(!asked.isEmpty)
        #expect(!asked.contains { $0.hasSuffix(".cooperative") }, "\(asked)")
    }

    /// An unreplayable call is out of the replayed share's denominator, never judged and so no evidence either way, and a grep of one file for a literal is out of it as a text search; the old denominator, which held both as misses, is printed beside the new one.
    @Test func anUnreplayableCallIsOutOfTheReplayedDenominatorAndTheOldShareIsPrintedBeside() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let gone = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-gone").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            Self.call("cd \(gone) && cat Sources/App/Depot.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Depot"),
            Self.call("grep -n \"#127\" Sources/App/Depot.swift", id: "c3", cwd: root.path, at: "2026-09-20T10:02:00Z"),
            TranscriptFixture.toolResult(id: "c3", isError: false, text: ""),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    1  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains(
            "  replayed share 100% = (indexed 0 + recovered 1) / 1 — the audit's own 0% — on the old denominator 33% = … / 3 (text searches in one file +1, unreplayable +1, not worth +0)"
        ), "\(section)")
    }
}

extension TranscriptAuditReplayTests {
    /// A window behind a `cd` and in front of `|| true` is placed as the same window without either — `true` prints nothing, so the hook reads the line as the window alone — and a window of a file an earlier recovered answer showed is therefore never left still cold as `noLookup`.
    @Test func aWindowBehindACdAndASilentFallbackIsNotLeftStillCold() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 80))\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.call("sed -n 1,170p Sources/App/Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Gizmo"),
            Self.call("cd Sources/App && sed -n 100,120p Gizmo.swift || true", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func part25"),
        ], hook: hook)

        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
    }

    /// A window behind a `cd` and in front of a `||` whose tail could print — or read a file of its own — runs where the `cd` moved whatever the tail does, so it is placed there: a window of a file an earlier window already showed is a re-read at the scan, never a cold lookup left still cold as `noLookup`.
    @Test(arguments: ["|| echo x", "|| sed -n 1,5p Gizmo.swift"])
    func aWindowInFrontOfAFallbackThatPrintsIsPlacedBehindItsCd(fallback: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0) // \(String(repeating: "x", count: 80))\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let section = try await Self.replayed([
            Self.call("sed -n 1,170p Sources/App/Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Gizmo"),
            Self.call("cd Sources/App && sed -n 100,120p Gizmo.swift \(fallback)", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "func part25"),
        ], hook: hook)

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
    }

    /// The directory a cold lookup's relative file is read from follows every literal `cd` before it — one after another, or an absolute one — as the hook and the scan place it, in front of a `||` whatever its tail — the list in front of it runs either way — and no move it cannot follow: a computed word, `cd -`, a subshell, a `cd` behind `||`, a lookup in front of a `||` whose tail moves again or ends the shell, or a lookup in the tail itself, which runs where the list in front of it failed.
    @Test(arguments: [
        ("cd Sources && cd App && sed -n 1,5p Gizmo.swift", "/repo/Sources/App"),
        ("cd /elsewhere/Kit && sed -n 1,5p Gizmo.swift", "/elsewhere/Kit"),
        ("sed -n 1,5p Gizmo.swift; cd Sources", "/repo"),
        ("cd $X && sed -n 1,5p Gizmo.swift", nil),
        ("cd - && sed -n 1,5p Gizmo.swift", nil),
        ("(cd Sources && sed -n 1,5p Gizmo.swift)", nil),
        ("true || cd Sources && sed -n 1,5p Gizmo.swift", nil),
        ("cd Sources && sed -n 1,5p Gizmo.swift || true", "/repo/Sources"),
        ("cd Sources && sed -n 1,5p Gizmo.swift || :", "/repo/Sources"),
        ("cd Sources && sed -n 1,5p Gizmo.swift || exit", nil),
        ("cd Sources && sed -n 1,5p Gizmo.swift || echo none", "/repo/Sources"),
        ("cd Sources && sed -n 1,5p Gizmo.swift || sed -n 1,5p Other.swift", "/repo/Sources"),
        ("cd Sources && sed -n 1,5p Gizmo.swift || cd ..", nil),
        ("cd Sources || echo none; sed -n 1,5p Gizmo.swift", nil),
        ("pushd Sources && sed -n 1,5p Gizmo.swift", nil),
    ] as [(String, String?)])
    func aRelativeFileIsReadFromWhereTheLiteralCdsMove(command: String, directory: String?) {
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]

        #expect(TranscriptReplay.directory(resolving: "Gizmo.swift", call: payload, cwd: "/repo") == directory)
    }

    /// A window whose answer would be no smaller than the lines it prints is reported under its own rule, the worth the index lost on, never as a lookup it had no answer for.
    @Test func aWindowNoSmallerThanItsAnswerIsReportedUnderItsOwnRule() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let verdict = await Self.verdict(of: "sed -n '100,119p' Sources/App/Depot.swift", cwd: root.path, hook: hook)

        #expect(verdict?.rule == InPlaceAnswerer.Withholding.notSmaller.rawValue, "\(String(describing: verdict))")
    }

    /// A bounded answer smaller than its window only while its closing line denies the saving is never served, and the replay counts the window as let run on worth.
    ///
    /// The line claiming a saving would leave the refusal no smaller than the lines asked for, and the shorter line denying one makes it smaller again, so it was once served saying it saved nothing. Padding a body line grows the window a byte at a time and nothing the answer lists, so every width across that point is weighed: below it the window runs as `notSmaller`, and past it as `linesNotShown`, since a members answer showing none of the window's lines is held to a saving of ``InPlaceAnswer/windowSavingFloor``.
    @Test
    func aBoundedAnswerThatCanOnlyDenyItsSavingRuns() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let pristine = try String(contentsOf: file, encoding: .utf8)
        let command = "sed -n '50,54p' Sources/App/Depot.swift"
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))
        let pad = { (width: Int) throws -> Int in
            var rows = pristine.components(separatedBy: "\n")
            rows[49] += " //" + String(repeating: "x", count: width)
            try rows.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            return rows[49 ..< 54].reduce(0) { $0 + $1.utf8.count + 1 }
        }
        let roomyWidth = 600 + InPlaceAnswer.windowSavingFloor
        let roomySource = try pad(roomyWidth)
        guard case let .answered(roomy) = try await Self.outcome(of: match) else {
            Issue.record("a padded window is answered")
            return
        }
        #expect(roomy.calls.map(\.target) == ["Sources/App/Depot.swift:50-54"])
        let start = roomyWidth - (roomySource - roomy.reason.utf8.count) - 60
        var reasons = Set<InPlaceAnswerer.Withholding>()
        for width in start ... start + 90 {
            _ = try pad(width)
            let outcome = try await Self.outcome(of: match)
            guard case let .withheld(why) = outcome, [.notSmaller, .linesNotShown].contains(why) else {
                Issue.record("width \(width) is let run, got \(outcome)")
                continue
            }
            reasons.insert(why)
        }
        #expect(reasons == [.notSmaller, .linesNotShown], "the sweep crosses the break-even point")
        _ = try pad(start + 90)
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let verdict = await TranscriptAuditReplayTests.verdict(of: command, cwd: root.path, hook: hook)

        #expect(verdict?.rule == InPlaceAnswerer.Withholding.linesNotShown.rawValue, "\(String(describing: verdict))")
    }

    /// A read of a file holding a parse error — whole, a window the whole digest answers, or windows answered by the members they overlap — runs as `parseError`, and the replay counts it there, since the digest is what the broken parse produced rather than the file.
    @Test(arguments: [
        "cat Sources/App/Depot.swift",
        "sed -n '2,180p' Sources/App/Depot.swift",
        "sed -n '2,180p' Sources/App/Depot.swift && cat Sources/App/Alpha.swift",
    ])
    func aReadOfAFileWithAParseErrorRuns(command: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: 80)
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path))
        guard case .answered = try await Self.outcome(of: match) else {
            Issue.record("the read is answered while the file parses")
            return
        }
        try (String(contentsOf: file, encoding: .utf8) + "}\n").write(to: file, atomically: true, encoding: .utf8)

        #expect(try await Self.outcome(of: match) == .withheld(.parseError))
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let verdict = await Self.verdict(of: command, cwd: root.path, hook: hook)
        #expect(verdict?.rule == InPlaceAnswerer.Withholding.parseError.rawValue, "\(String(describing: verdict))")
    }

    /// What the answerer does with `match` alone, with a back-off of its own and room enough never to run out of time.
    private static func outcome(of match: InPlaceShape.Match) async throws -> InPlaceAnswerer.Outcome {
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
        }
    }

    /// The Xcode server's read, search and glob are put to the hook as the built-in ones are, since the hook is registered for them, so none is left still cold as a call it never sees.
    @Test func theXcodeServersLookupsAreJudgedByTheHook() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let depot = root.appendingPathComponent("Sources/App/Depot.swift").path

        let section = try await Self.replayed([
            Self.use("mcp__xcode__XcodeRead", input: ["filePath": depot], id: "x1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "x1", isError: false, text: "struct Depot"),
            Self.use("mcp__xcode__XcodeGrep", input: ["output_mode": "content", "pattern": "struct Depot", "path": root.path], id: "x2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "x2", isError: false, text: "Sources/App/Depot.swift:2:struct Depot {"),
            Self.use("mcp__xcode__XcodeGlob", input: ["pattern": "**/Depot.swift", "path": root.path], id: "x3", cwd: root.path, at: "2026-09-20T10:02:00Z"),
            TranscriptFixture.toolResult(id: "x3", isError: false, text: depot),
        ])

        #expect(section.contains("  cold            3  the lookups the audit calls cold"), "\(section)")
        #expect(!section.contains { $0.contains("notHooked") }, "\(section)")
    }

    /// An answer that runs out of time in the session backs off that shape in the session alone: its subagent's identical read a minute later is tried and runs out of time of its own, never withheld by the session's back-off.
    @Test func anOverrunBacksOffOnlyTheContextItHappenedIn() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let session = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let subagents = session.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ].joined(separator: [0x0A])).write(to: session)
        try Data([
            Self.call("cat Sources/App/Depot.swift", id: "a1", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "a1", isError: false, text: "struct Depot"),
        ].joined(separator: [0x0A])).write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        // No time at all to answer in, so every answer tried runs out of time: a read withheld without being tried was backed off.
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: 0)

        let section = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.section(projectsDirectory: session.deletingLastPathComponent(), since: nil, transcript: session.path, hook: hook)
        }

        #expect(section.contains("  cold            2  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("         2  overTime"), "\(section)")
        #expect(!section.contains { $0.contains(InPlaceAnswerer.Withholding.backingOff.rawValue) }, "\(section)")
    }

    /// The audit and its replay read one snapshot of the transcripts, so a lookup a live session writes after it is counted by neither, and the audit's own share the replay prints is the audit section's.
    @Test func theAuditAndItsReplayReadOneSnapshotOfAGrowingTranscript() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "Alpha"]) + [
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: transcript)
        let projects = transcript.deletingLastPathComponent()
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: transcript.path)

        // The session goes on working after the snapshot: a second cold lookup lands before either pass reads.
        let later = try [
            Self.call("cat Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(later.joined(separator: [0x0A])))
        try handle.close()

        let audit = TranscriptAudit.render(projectsDirectory: projects, transcript: transcript.path, snapshot: snapshot)
            .components(separatedBy: "\n")
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)
        let replay = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.sections(projectsDirectory: projects, since: nil, transcript: transcript.path, hook: hook, snapshot: snapshot).report
        }

        #expect(audit.contains("  cold           1  went around the index  ← the misses"), "\(audit)")
        #expect(audit.contains { $0.hasPrefix("  indexed        1  served by sift — 50% of the lookups that had a choice") }, "\(audit)")
        #expect(replay.contains("  cold            1  the lookups the audit calls cold"), "\(replay)")
        #expect(replay.contains { $0.contains("— the audit's own 50% —") }, "\(replay)")
    }

    /// A replay's stores all resolve under the scratch home it is given: `HookReplay`'s own doc names this — "neither reads nor moves anything a live session relies on" — and every path anything it writes lands on falls inside `directory`, never a real `~/.sift`.
    @Test func theReplaysStoresAllResolveUnderItsOwnScratchHome() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let scratchHome = try TemporaryDirectory.make("hook-replay")
        let hook = HookReplay(directory: scratchHome, timeBudget: InPlaceAnswerTests.roomy)

        _ = try await Self.replayed([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ], hook: hook)

        let resolvedHome = scratchHome.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: scratchHome, includingPropertiesForKeys: nil)
        var written: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            written.append(file)
        }

        #expect(!written.isEmpty, "the replay should have written at least one store under its own scratch home")
        #expect(written.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(resolvedHome) }, "\(written.map(\.path))")
    }

    /// A call's timestamp, not wall time, drives when an overrun's back-off has elapsed: two calls of the same shape ten minutes apart on the transcript's own clock — both dated years before the suite runs — back off only within that window, so the second is tried again rather than withheld on a window the wall clock, close to elapsing on neither reading, would say had not even started.
    @Test func aBackoffWindowElapsesOnTheTranscriptsClockNotWallTime() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: 0)

        let section = try await Self.replayed([
            Self.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2020-01-01T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            Self.call("cat Sources/App/Depot.swift", id: "c2", cwd: root.path, at: "2020-01-01T10:10:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Depot"),
        ], hook: hook)

        #expect(section.contains("         2  overTime"), "\(section)")
        #expect(!section.contains { $0.contains(InPlaceAnswerer.Withholding.backingOff.rawValue) }, "\(section)")
    }

    /// A subagent transcript is replayed as its own context: its cold lookup, and the recovered outcome the hook gives it, are counted even where the session transcript beside it makes no calls of its own.
    @Test func aSubagentTranscriptIsReplayedAsItsOwnContextWithItsOwnTally() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let session = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let subagents = session.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{\"type\": \"summary\"}".utf8).write(to: session)
        try Data([
            Self.call("cat Sources/App/Depot.swift", id: "a1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "a1", isError: false, text: "struct Depot"),
        ].joined(separator: [0x0A])).write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)

        let section = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.section(projectsDirectory: session.deletingLastPathComponent(), since: nil, transcript: session.path, hook: hook)
        }

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
    }

    /// A cold lookup that is scored then retracted by its own line's later error leaves the counts as they were before it was scored — net zero — whether or not the retraction lands on the same day as the call it takes back.
    @Test func aRetractedColdLookupLeavesTheCountsAsBeforeItWasScoredAcrossADayBoundary() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let retraction: [String: Any] = [
            "type": "user",
            "timestamp": "2026-09-21T00:01:00Z",
            "message": ["content": [["type": "tool_result", "tool_use_id": "c1", "is_error": true, "content": [["type": "text", "text": "boom"]]]]],
        ]
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            Self.call("grep -n \"struct Depot\" Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T23:59:00Z"),
            JSONSerialization.data(withJSONObject: retraction),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await Self.replaySection(of: transcript)

        #expect(section.contains("  cold            0  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       0  the hook would now answer these in place"), "\(section)")
    }
}

extension TranscriptAuditReplayTests {
    /// The same search sent twice in one turn, the first let through, is scored cold again on the second's result; the replay puts that lookup down to the second call and the verdict its own line was given, so both searches read alike and none is counted without a call.
    @Test func aSearchRescoredOnItsResultKeepsItsCallAndVerdict() throws {
        let root = try TemporaryDirectory.make("root")
        let search: [String: Any] = ["output_mode": "content", "pattern": "SummaryState", "glob": "*.swift"]
        let context = try Self.replayedContext([
            TranscriptTurns.call("Grep", id: "g1", input: search, turn: "m1", cwd: root.path),
            TranscriptTurns.call("Grep", id: "g2", input: search, turn: "m1", cwd: root.path),
            TranscriptTurns.result(id: "g1", text: "Sources/App/SummaryState.swift:12"),
            TranscriptTurns.result(id: "g2", text: "Sources/App/SummaryState.swift:12"),
        ])

        #expect(context.tally.cold == 2)
        #expect(context.replay.stillCold == ["noLookup": 2], "\(context.replay)")
        #expect(context.replay.ungroupedStillCold(for: "noLookup") == 0)
    }

    /// A shell line scored after an earlier call of its turn taken as answered, whose two readings name different calls, is scored again on its result once that call turns out to have been let through; the retraction and the new lookup are both the line's own, so it keeps its verdict and none is counted without a call.
    @Test func aShellLineRescoredOnItsResultUnderAnotherVerbKeepsItsCallAndVerdict() throws {
        let root = try TemporaryDirectory.make("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        for name in ["Depot", "Gadget"] {
            try "struct \(name) {}\n".write(to: root.appendingPathComponent("Sources/App/\(name).swift"), atomically: true, encoding: .utf8)
        }
        let first = "grep -rn Depot Sources"
        let context = try Self.replayedContext([
            TranscriptTurns.call("Bash", id: "c1", input: ["command": first], turn: "m1", cwd: root.path),
            TranscriptTurns.call("Bash", id: "c2", input: ["command": "\(first) && grep -n 'case ' Sources/App/Gadget.swift"], turn: "m1", cwd: root.path),
            TranscriptTurns.result(id: "c1", text: "Sources/App/Depot.swift:3:struct Depot {"),
            TranscriptTurns.result(id: "c2", text: "Sources/App/Gadget.swift:5:    case one"),
        ])

        #expect(context.tally.cold == 2)
        #expect(context.replay.stillCold == ["noLookup": 2], "\(context.replay)")
        #expect(context.replay.ungroupedStillCold(for: "noLookup") == 0)
    }

    /// One context's replay of `lines` against a hook that lets every search through.
    private static func replayedContext(_ lines: [Data]) throws -> ContextReplay {
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let probes = ReplayProbes(since: nil, until: nil, timeZone: .current, belowFloor: { _ in false }, couldAnswer: { _, _ in true }, memberExists: { _, _, _ in true })
        return TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: FixedVerdictHook())
    }
}

private extension TranscriptAuditReplayTests {
    /// What `hook` decides about one `command` run from `cwd`, judged on a thread of its own for the reason ``replayed(_:hook:)`` gives.
    static func verdict(of command: String, cwd: String, hook: HookReplay) async -> ReplayVerdict? {
        let instant = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")
        return await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = [
                "session_id": "replayed-session",
                "tool_name": "Bash",
                "tool_input": ["command": command],
            ]
            return hook.verdict(payload: payload, cwd: cwd, at: instant, decides: true)
        }
    }
}
