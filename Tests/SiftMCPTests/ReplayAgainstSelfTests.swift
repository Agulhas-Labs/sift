//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay --against` putting this build against itself: whatever the machine's indexes do during the run, two identical hooks list no difference.
@Suite(.temporaryDirectories, .hermeticIndexes)
struct ReplayAgainstSelfTests {
    /// A name that leaves the index part way through the run moves no call: both hooks judge it as the index stands when the call is put to them, never this one against the run's snapshot and the other afresh.
    @Test
    func aNameThatLeavesTheIndexMidRunMovesNoCall() async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let root = try MCPTestRepo.make(declaring: "QzxGone")
        try await SiftEngine(directory: root).ensureFresh()
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        // The shapes that moved: a piped line, one grep of two names, and a line of several statements.
        let commands = ["grep -rn QzxGone Sources | head -3", "git grep -l -e QzxGone -e QzxAlsoGone -- Sources", "grep -rn QzxGone Sources; echo done"]
        let lines = try commands.enumerated().map { index, command in
            try TranscriptAuditReplayTests.call(command, id: "c\(index)", cwd: root.path, at: "2026-09-20T10:00:0\(index)Z")
        }
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let state = RunIndexState()
        defer { state.close() }
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: transcript.path, indexes: state)
        // The run reads the store while it still declares the name; then another session renames it away and the store follows.
        #expect(AdvisableName.memoised(in: state)("QzxGone", root.path))
        try "struct QzxRenamed {}\n".write(to: root.appendingPathComponent("Sources/App/QzxGone.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        #expect(!AdvisableName.couldAnswer("QzxGone", from: root.path))
        let scratch = try TemporaryDirectory.make("replay")
        // The child reads a home of its own with no repository registered, as the in-process hook reads the empty registry the suite scopes, so neither sees this machine's `~/.sift/roots.json`.
        let home = try TemporaryDirectory.make("home")

        let section = try await InPlaceAnswerTests.onItsOwnThread {
            Result {
                try AuditCommand.replaySection(
                    projectsDirectory: projects,
                    since: nil,
                    transcript: transcript.path,
                    scratch: scratch,
                    timeBudget: InPlaceAnswerTests.roomy,
                    against: sift,
                    againstEnvironment: ["CFFIXED_USER_HOME": home.path],
                    snapshot: snapshot
                )
            }
        }.get()

        #expect(section.contains("  no difference: the two hooks judge all 3 calls in the window alike"), "\(section)")
        #expect(!section.contains { $0.contains("the other binary failed") }, "\(section)")
    }

    /// A `replay-hook` child reads the home it is given: the injected environment reaches it, and without one it keeps this process's.
    @Test
    func theChildReadsTheHomeItIsGiven() async throws {
        let home = try TemporaryDirectory.make("home")
        let stubDirectory = try TemporaryDirectory.make("stub")
        let stub = stubDirectory.appendingPathComponent("sift")
        let answer = #"echo "{\"hooked\":true,\"rule\":\"probe\",\"token\":\"$CFFIXED_USER_HOME\"}""#
        try "#!/bin/sh\ncase \" $* \" in *\" --help \"*) exit 0 ;; esac\ncat > /dev/null\n\(answer)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let state = stubDirectory.appendingPathComponent("against", isDirectory: true)

        let (given, inherited) = await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "echo 1"]]
            let given = ExternalReplayHook(binary: stub, directory: state, timeBudget: 30, environment: ["CFFIXED_USER_HOME": home.path])
            let inherited = ExternalReplayHook(binary: stub, directory: state, timeBudget: 30)

            return (
                given.verdict(payload: payload, cwd: "/", at: nil, decides: true)?.token,
                inherited.verdict(payload: payload, cwd: "/", at: nil, decides: true)?.token
            )
        }

        #expect(given == home.path)
        #expect(inherited != home.path)
    }
}
