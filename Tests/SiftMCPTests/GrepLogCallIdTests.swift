//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Every suppression-log entry the hook writes names the `tool_use_id` of the call it judged, where the harness gave one — the audit's only way back from a verdict to the transcript line it belongs to.
@Suite(.temporaryDirectories)
struct GrepLogCallIdTests {
    /// A refusal `worthAsking` withholds on its own account — no target named at all — is logged against the call it judged, on the main path a plain lookup takes.
    @Test
    func aWorthAskingRefusalIsLoggedAgainstItsCall() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let alternation = #"grep -rn -i "every response\|every answer" Docs Sources --include=*.md --include=*.swift"#
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": alternation], "tool_use_id": "toolu_w1"]

        #expect(PreToolUseCommand.lookup(command: nil, payload: payload, noting: recording.log, couldAnswer: { _, _ in true }) == nil)

        #expect(recording.rules == ["untargeted"])
        #expect(recording.calls == ["toolu_w1"])
    }

    /// The one bare refusal left when nothing answers in place — no digest, no denial — still names the call it judged.
    @Test
    func aNotAnswerableRefusalIsLoggedAgainstItsCall() throws {
        let scratch = try TemporaryDirectory.make("not-answerable-call")
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let payload: [String: Any] = [
            "tool_name": "Grep",
            "tool_input": ["output_mode": "content", "pattern": #"static\|case "#, "path": "/repo/Sources/App/Depot.swift"],
            "tool_use_id": "toolu_n1",
        ]
        let lookup = try #require(PreToolUseCommand.lookup(command: nil, payload: payload, in: "/repo", noting: recording.log, couldAnswer: { _, _ in true }))

        let outcome = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
            payload: payload,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: recording.log
        ) { _, _, _ in .withheld(.notExact) }

        #expect(outcome.verdict.rule == "notAnswerable")
        #expect(recording.rules == ["notAnswerable"])
        #expect(recording.calls == ["toolu_n1"])
    }

    /// A whole read of a file this context has already had digested is let through, and the entry is logged against the read's own call.
    @Test
    func anAlreadyDigestedReadIsLoggedAgainstItsCall() throws {
        let root = try TemporaryDirectory.makeForProcess("already-digested-call")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("Sources/App/SummaryState.swift").path
        let log = try DigestedFilesTests.UsageLogFile([
            ["tool": "digest", "target": "SummaryState", "root": root.path, "ms": 3, "ok": true, "session": "s1", "outBytes": 900, "srcBytes": 12000],
        ])
        defer { log.cleanup() }
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": path], "session_id": "s1", "tool_use_id": "toolu_d1"]

        #expect(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            noting: recording.log,
            digested: log.digested,
            couldAnswer: { _, _ in true },
            resolvingDigests: { target, atRoot in atRoot == root.path ? "Sources/App/\(target).swift" : nil }
        ) == nil)

        #expect(recording.rules == ["alreadyDigested"])
        #expect(recording.calls == ["toolu_d1"])
    }

    /// An answer leaving an alternation's prose to a search is logged against the call that was answered.
    @Test
    func aPartialAlternationAnswerIsLoggedAgainstItsCall() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        let command = #"grep -rn "Depot\|stale index" Sources"#
        let directory = try TemporaryDirectory.make("partial-alternation-call")
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "agent_id": "a1", "tool_use_id": "toolu_p1"]
        let lookup = try #require(PreToolUseCommand.lookup(command: nil, payload: payload, in: root.path, noting: recording.log, couldAnswer: { _, _ in true }))
        let backoff = try InPlaceAnswerTests.backoff()

        let verdict = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["tool_name": "Bash", "tool_input": ["command": command], "agent_id": "a1", "tool_use_id": "toolu_p1"],
                cwd: root.path,
                ledger: AdviceLedger(directory: directory.appendingPathComponent("advice")),
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
                suppressions: recording.log,
                answerer: { match, serverGone, _ in
                    InPlaceAnswerer.answer(
                        match.call,
                        from: match.directory,
                        serverGone: serverGone,
                        wholeCommand: match.isWholeCommand,
                        timeBudget: InPlaceAnswerTests.roomy,
                        backoff: backoff
                    )
                }
            ).verdict
        }

        #expect(verdict.token == "in-place")
        #expect(recording.rules == ["partialAlternation"])
        #expect(recording.calls == ["toolu_p1"])
    }

    /// A toolchain run silenced as a gate leg is logged against the call it silenced.
    @Test
    func aGateLegRefusalIsLoggedAgainstItsCall() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build"],
            "tool_use_id": "toolu_g1",
        ]

        #expect(PreToolUseCommand.lookup(command: nil, payload: payload, noting: recording.log, couldAnswer: { _, _ in true }) == nil)

        #expect(recording.rules == ["gateLeg"])
        #expect(recording.calls == ["toolu_g1"])
    }

    /// A shell read of files this context has had digested is let through, and the entry is logged against the line's own call.
    @Test
    func anAlreadyDigestedShellReadIsLoggedAgainstItsCall() throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let lookup = try fixture.shellRead("cat Sources/App/Shell.swift")

        let verdict = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: fixture.context("s1"),
            payload: ["tool_name": "Bash", "agent_id": "a1", "tool_use_id": "toolu_s1"],
            cwd: fixture.repo.path,
            ledger: fixture.ledger,
            usage: UsageLog(fileURL: fixture.stores.appendingPathComponent("usage.jsonl")),
            suppressions: recording.log
        ).verdict

        #expect(verdict.rule == "alreadyDigested")
        #expect(recording.rules == ["alreadyDigested"])
        #expect(recording.calls == ["toolu_s1"])
    }

    /// A shell search of another revision's tree is silenced, and the entry is logged against the call it silenced.
    @Test
    func anotherRevisionSearchIsLoggedAgainstItsCall() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let payload: [String: Any] = [
            "tool_name": "Bash",
            "tool_input": ["command": "git grep -n pending feature -- 'Sources/*.swift'"],
            "tool_use_id": "toolu_r1",
        ]

        #expect(PreToolUseCommand.lookup(command: nil, payload: payload, noting: recording.log, couldAnswer: { _, _ in true }) == nil)

        #expect(recording.rules == ["anotherRevision"])
        #expect(recording.calls == ["toolu_r1"])
    }
}
