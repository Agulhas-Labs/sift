//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Cursor runs the Claude Code hooks it imports from `~/.claude/settings.json` and shows a refusal to the user rather than the model, so every hook prints nothing on a Cursor payload and exits 0.
///
/// Driven through the built binary, because the claim is about the process each registered event runs: what reaches stdout and the exit status. Each payload is the representative Cursor payload in `Fixtures/cursor-hook-payloads.json` with the fields the hook reads in Claude Code's form laid over it — the shape in which the import would let the hook act at all — so the same payload without Cursor's common fields draws an answer, and the silence is Cursor's recognition rather than a payload the hook ignores anyway.
@Suite(.temporaryDirectories)
struct CursorHookPayloadTests {
    @Test(arguments: Event.allCases)
    func aCursorPayloadDrawsNothingAndExitsZero(event: Event) throws {
        let scene = try Scene()
        let run = try scene.run(event, payload: scene.payload(for: event))

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "\(event.subcommand) printed \(run.printed)")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scene.home.path)) ?? []
        #expect(left.isEmpty, "\(event.subcommand) wrote \(left) before recognising Cursor")
    }

    /// Cursor's `cursor_version` is not established to reach an imported hook, so its other common fields identify it alone.
    @Test
    func aPayloadWithoutCursorVersionIsStillRecognisedByItsOtherCommonFields() throws {
        let scene = try Scene()
        var payload = try scene.payload(for: .preToolUse)
        payload["cursor_version"] = nil
        payload["workspace_roots"] = nil
        payload["hook_event_name"] = "preToolUse"
        #expect(payload["conversation_id"] != nil && payload["generation_id"] != nil)
        #expect(CursorHookPayload.recognises(payload))
        let run = try scene.run(.preToolUse, payload: payload)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
        #expect(CursorHookPayload.recognises(["workspace_roots": ["/r"]]))
    }

    @Test(arguments: Event.allCases)
    func theSamePayloadWithoutCursorsFieldsIsAnswered(event: Event) throws {
        let scene = try Scene()
        var payload = try scene.payload(for: event)
        for field in ["cursor_version", "conversation_id", "generation_id", "workspace_roots"] {
            payload[field] = nil
        }
        let run = try scene.run(event, payload: payload)

        #expect(run.status == 0)
        #expect(!run.printed.isEmpty, "\(event.subcommand) printed nothing for a payload it should answer")
    }

    /// A probe of the advice hook is told why a Cursor payload went through, apart from every other allow.
    @Test
    func aProbeNamesCursorAsTheRule() throws {
        let scene = try Scene()
        let run = try scene.run(.preToolUse, payload: scene.payload(for: .preToolUse), arguments: ["--verdict"])

        #expect(run.printed == "allowed\t\tcursor\n")
    }

    /// Claude Code's own payloads, one per event the hook is registered for, are never taken for Cursor's.
    @Test
    func noClaudeCodePayloadIsTakenForCursors() {
        let common: [String: Any] = ["session_id": "s1", "transcript_path": "/t.jsonl", "cwd": "/repo", "permission_mode": "default"]
        let events: [[String: Any]] = [
            ["hook_event_name": "SessionStart", "source": "startup", "model": "claude-opus-4-7"],
            ["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "general-purpose"],
            ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "swift build"], "tool_use_id": "t1"],
            ["hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": ["file_path": "/repo/A.swift"], "tool_response": [:], "tool_use_id": "t2"],
            ["hook_event_name": "Stop", "stop_hook_active": false],
            ["hook_event_name": "SubagentStop", "stop_hook_active": false, "agent_id": "a1", "agent_transcript_path": "/a.jsonl"],
        ]

        for event in events {
            #expect(!CursorHookPayload.recognises(common.merging(event) { $1 }), "\(event)")
        }
    }
}

extension CursorHookPayloadTests {
    /// Every event `install-hook` registers, by Cursor's name for it.
    enum Event: String, CaseIterable {
        case sessionStart, subagentStart, preToolUse, postToolUse, stop, subagentStop

        var subcommand: String {
            switch self {
            case .sessionStart, .subagentStart: "session-start"
            case .preToolUse: "pre-tool-use"
            case .postToolUse: "post-tool-use"
            case .stop, .subagentStop: "stop"
            }
        }
    }
}

private extension CursorHookPayloadTests {
    /// A repository with a package at its root and a Swift file edited in a transcript, and a home, advice directory and usage log of the test's own.
    struct Scene {
        let stop: StopGateFixture
        let home: URL
        let transcript: String
        let broken: String

        init() throws {
            stop = try StopGateFixture()
            home = try TemporaryDirectory.make("cursor-home")
            transcript = try stop.transcript([StopGateFixture.edit("t1", path: stop.depot), StopGateFixture.result("t1")])
            broken = stop.repo.appendingPathComponent("Broken.swift").path
            try "struct Broken {\n    func f( {\n}\n".write(toFile: broken, atomically: true, encoding: .utf8)
        }

        /// The fixture's Cursor payload for `event`, with the fields the hook reads laid over it in Claude Code's form.
        func payload(for event: Event, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
            let url = try #require(Bundle.module.url(forResource: "cursor-hook-payloads", withExtension: "json", subdirectory: "Fixtures"), sourceLocation: sourceLocation)
            let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
            let common = try #require(fixture["common"] as? [String: Any], sourceLocation: sourceLocation)
            let events = try #require(fixture["events"] as? [String: Any], sourceLocation: sourceLocation)
            let own = try #require(events[event.rawValue] as? [String: Any], sourceLocation: sourceLocation)
            var payload = common.merging(own) { $1 }
            payload["session_id"] = "cursor-session"
            payload["cwd"] = stop.repo.path
            switch event {
            case .sessionStart, .subagentStart:
                break
            case .preToolUse:
                payload["tool_name"] = "Bash"
                payload["tool_input"] = ["command": "swift build"]
            case .postToolUse:
                payload["tool_input"] = ["file_path": broken]
            case .stop, .subagentStop:
                payload["transcript_path"] = transcript
                payload["agent_transcript_path"] = transcript
            }
            return payload
        }

        /// Runs this build's `sift <event's subcommand>` with `payload` on stdin: its exit status and what it printed.
        func run(
            _ event: Event,
            payload: [String: Any],
            arguments: [String] = [],
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> (status: Int32, printed: String) {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let process = Process()
            process.executableURL = binary
            process.arguments = [event.subcommand] + arguments
            process.currentDirectoryURL = stop.repo
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
            environment["SIFT_NO_ADVICE"] = nil
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            try input.fileHandleForWriting.write(JSONSerialization.data(withJSONObject: payload))
            input.fileHandleForWriting.closeFile()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")
        }
    }
}
