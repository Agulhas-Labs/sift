//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `sift session-start --agent cursor`, driven through the built binary with Cursor's `sessionStart` payload as a probe of the Cursor CLI recorded it: the primer Claude Code is given, as `additional_context`, and nothing at all where the payload cannot be read or no Swift is in view.
///
/// Every run starts in a Swift repository, so a hook that fell back to its own directory instead of the payload's would print there.
@Suite(.temporaryDirectories)
struct CursorSessionStartTests {
    /// The primer a Claude Code session starting in the same repository is given, whole, as Cursor's `additional_context` and nothing else.
    @Test func cursorsSessionStartGetsTheClaudePrimerAsAdditionalContext() throws {
        let scene = try Scene()
        let claude = try scene.run(["cwd": scene.repo.path, "hook_event_name": "SessionStart", "source": "startup"], agent: nil)
        try #require(claude.status == 0)
        try #require(claude.printed.hasSuffix("\n") && claude.printed.count > 1, "the Claude Code start printed no primer: \(claude.printed)")
        let primer = String(claude.printed.dropLast())

        let cursor = try scene.run(scene.cursor())
        let expected = try JSONSerialization.data(withJSONObject: ["additional_context": primer], options: [.sortedKeys, .withoutEscapingSlashes])

        #expect(cursor.status == 0)
        #expect(cursor.printed == String(bytes: expected, encoding: .utf8).map { $0 + "\n" })
    }

    /// Every payload this cannot read, and one whose workspace holds no Swift, prints nothing and exits 0.
    @Test(arguments: Unread.allCases)
    func aPayloadThisCannotReadDrawsNothing(unread: Unread) throws {
        let scene = try Scene()
        let run = try scene.run(stdin: unread.stdin(scene))

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }
}

extension CursorSessionStartTests {
    /// A variant of the readable payload that must draw silence.
    enum Unread: String, CaseIterable {
        case garbage
        case emptyObject
        case noRoots
        case emptyRoots
        case relativeRoot
        case emptyRoot
        case rootNotText
        case otherEvent
        case claudeSpelling
        case noSwiftInView

        func stdin(_ scene: Scene) throws -> Data {
            var payload = scene.cursor()
            switch self {
            case .garbage:
                return Data("{not json".utf8)
            case .emptyObject:
                payload = [:]
            case .noRoots:
                payload["workspace_roots"] = nil
            case .emptyRoots:
                payload["workspace_roots"] = [String]()
            case .relativeRoot:
                payload["workspace_roots"] = ["App"]
            case .emptyRoot:
                payload["workspace_roots"] = [""]
            case .rootNotText:
                payload["workspace_roots"] = [7]
            case .otherEvent:
                payload["hook_event_name"] = "postToolUse"
            case .claudeSpelling:
                payload["hook_event_name"] = "SessionStart"
            case .noSwiftInView:
                payload["workspace_roots"] = [scene.plain.path]
            }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }

    /// A committed Swift repository the hook runs in, a directory with no Swift beside it, and a home of the test's own.
    struct Scene {
        let repo: URL
        let plain: URL
        let home: URL

        init() throws {
            repo = try MCPTestRepo.make()
            plain = try TemporaryDirectory.make("cursor-plain")
            try "notes\n".write(to: plain.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            home = try TemporaryDirectory.make("cursor-home")
        }

        /// Cursor's `sessionStart` payload, its fields as a probe of the Cursor CLI recorded them, with this scene's repository as its workspace.
        func cursor() -> [String: Any] {
            [
                "conversation_id": "c1", "generation_id": "g1", "model": "default", "is_background_agent": false, "session_id": "s1",
                "hook_event_name": "sessionStart", "cursor_version": "2026.09.28-64d2043", "workspace_roots": [repo.path],
                "user_email": "user@example.com", "transcript_path": home.appendingPathComponent("absent.jsonl").path,
            ]
        }

        func run(_ payload: [String: Any], agent: String? = "cursor") throws -> (status: Int32, printed: String) {
            try run(stdin: JSONSerialization.data(withJSONObject: payload), agent: agent)
        }

        /// Runs this build's `sift session-start`, with `--agent` where one is given, on `stdin` from inside the repository: its exit status and what it printed.
        func run(stdin: Data, agent: String? = "cursor", sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, printed: String) {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["session-start"] + (agent.map { ["--agent", $0] } ?? [])
            process.currentDirectoryURL = repo
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
            environment["SIFT_RUN_LOG"] = home.appendingPathComponent("run.jsonl").path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            input.fileHandleForWriting.closeFile()
            let printed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(bytes: printed, encoding: .utf8) ?? "")
        }
    }
}
