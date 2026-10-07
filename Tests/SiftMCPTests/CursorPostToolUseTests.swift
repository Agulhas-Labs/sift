//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// `sift post-tool-use --agent cursor`, driven through the built binary with Cursor's `postToolUse` payloads in the shapes a probe of the Cursor CLI recorded: what the Claude Code registration hands the model after the same write, as `additional_context`, and nothing at all for a payload it cannot read.
///
/// A probe saw Cursor report a search-and-replace edit as a `Write` of the whole new file, so a `Write` is the one tool read.
@Suite(.temporaryDirectories)
struct CursorPostToolUseTests {
    /// A write that leaves a Swift file unparseable: the reason Claude Code's block carries reaches Cursor's model as context.
    @Test func aWriteLeavingSwiftUnparseableHandsTheClaudeReasonAsContext() async throws {
        let scene = try await Scene()
        try Scene.broken.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        let claude = try scene.run(scene.claude(scene.catalogue, content: Scene.broken), agent: nil)
        let reason = try #require(Self.object(claude.printed)["reason"] as? String)

        let cursor = try scene.run(scene.cursor(scene.catalogue, content: Scene.broken))

        #expect(cursor.status == 0)
        #expect(cursor.printed == Self.additionalContext(reason))
    }

    /// A write adding a near duplicate: the nudge Claude Code is given reaches Cursor's model as context.
    @Test func aWriteAddingANearDuplicateHandsTheClaudeNudgeAsContext() async throws {
        let scene = try await Scene()
        try Scene.restocked.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        let claude = try scene.run(scene.claude(scene.catalogue, content: Scene.restocked), agent: nil)
        let specific = try #require(Self.object(claude.printed)["hookSpecificOutput"] as? [String: Any])
        let nudge = try #require(specific["additionalContext"] as? String)
        try await scene.setBack()

        let cursor = try scene.run(scene.cursor(scene.catalogue, content: Scene.restocked))

        #expect(cursor.status == 0)
        #expect(cursor.printed == Self.additionalContext(nudge))
    }

    /// Every payload this cannot read, and every call the Claude Code registration says nothing about, prints nothing and exits 0; each is a variant of a write that would draw context.
    @Test(arguments: Unread.allCases)
    func aPayloadThisCannotReadDrawsNothing(unread: Unread) async throws {
        let scene = try await Scene()
        try Scene.broken.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        let run = try scene.run(stdin: unread.stdin(scene), disabled: unread == .adviceOff)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// The line Cursor is expected to read `context` from, keys sorted and slashes bare as every hook answer is.
    static func additionalContext(_ context: String) -> String? {
        let data = try? JSONSerialization.data(withJSONObject: ["additional_context": context], options: [.sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(bytes: $0, encoding: .utf8) }.map { $0 + "\n" }
    }

    static func object(_ printed: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any], "printed \(printed)", sourceLocation: sourceLocation)
    }
}

extension CursorPostToolUseTests {
    /// A variant of a readable write of a broken Swift file that must draw silence.
    enum Unread: String, CaseIterable {
        case garbage
        case otherEvent
        case read
        case shell
        case indexCall
        case unprobedKey
        case relativeRoot
        case noRoots
        case noSession
        case notSwift
        case adviceOff

        func stdin(_ scene: Scene) throws -> Data {
            var payload = scene.cursor(scene.catalogue, content: Scene.broken)
            switch self {
            case .garbage:
                return Data("{not json".utf8)
            case .otherEvent:
                payload["hook_event_name"] = "preToolUse"
            case .read:
                payload["tool_name"] = "Read"
                payload["tool_input"] = ["file_path": scene.catalogue]
                payload["tool_output"] = "{\"file_path\":\"\(scene.catalogue)\",\"content_length\":24}"
            case .shell:
                payload["tool_name"] = "Shell"
                payload["tool_input"] = ["command": "echo hello", "cwd": "", "timeout": 30000]
                payload["tool_output"] = "{\"output\":\"hello\\n\",\"exitCode\":0}"
                payload["cwd"] = ""
            case .indexCall:
                payload["tool_name"] = "MCP:digest"
                payload["tool_input"] = ["target": "Sources/App/Catalogue.swift", "root": scene.repo.path]
            case .unprobedKey:
                payload["tool_input"] = ["file_path": scene.catalogue, "content": Scene.broken, "old_string": "x"]
            case .relativeRoot:
                payload["workspace_roots"] = ["App"]
            case .noRoots:
                payload["workspace_roots"] = nil
            case .noSession:
                payload["session_id"] = nil
                payload["conversation_id"] = nil
            case .notSwift:
                payload["tool_input"] = ["file_path": scene.repo.appendingPathComponent("notes.txt").path, "content": "hi\n"]
            case .adviceOff:
                break
            }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }

    /// An indexed repository whose `Depot.stock()` makes four calls, and a catalogue to write, with a home and advice directory of the test's own.
    struct Scene {
        static var catalogueSource: String {
            "struct Catalogue {\n    func count() -> Int {\n        1\n    }\n}\n"
        }

        /// The catalogue with a function making `Depot.stock()`'s four calls added.
        static var restocked: String {
            "struct Catalogue {\n    func count() -> Int {\n        1\n    }\n\n    func restock() -> Int {\n"
                + "        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
        }

        static var broken: String {
            "struct Catalogue {\n    func count( {\n}\n"
        }

        let repo: URL
        let home: URL

        init() async throws {
            repo = try MCPTestRepo.make(declaring: "Depot")
            let depot = "struct Depot {\n    func stock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
            try MCPTestRepo.add(["Sources/App/Depot.swift": depot, "Sources/App/Catalogue.swift": Self.catalogueSource, "notes.txt": "notes\n"], to: repo)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
            home = try TemporaryDirectory.make("cursor-home")
        }

        var catalogue: String {
            repo.appendingPathComponent("Sources/App/Catalogue.swift").path
        }

        /// Sets the index back to before the write and makes it again, so the added function is new to the index once more.
        func setBack() async throws {
            try Self.catalogueSource.write(toFile: catalogue, atomically: true, encoding: .utf8)
            try await SiftEngine(directory: repo, registry: nil).ensureFresh()
            try Self.restocked.write(toFile: catalogue, atomically: true, encoding: .utf8)
        }

        /// Cursor's `postToolUse` payload for a `Write` of `content` to `path`, its fields as a probe of the Cursor CLI recorded them.
        func cursor(_ path: String, content: String) -> [String: Any] {
            [
                "conversation_id": "c1", "generation_id": "g1", "model": "default", "tool_name": "Write",
                "tool_input": ["file_path": path, "content": content], "tool_output": "{\"file_path\":\"\(path)\",\"success\":true}",
                "duration": 20.064, "tool_use_id": "t1", "session_id": "cursor-session", "hook_event_name": "postToolUse",
                "cursor_version": "2026.09.28-64d2043", "workspace_roots": [repo.path], "user_email": "user@example.com",
                "transcript_path": home.appendingPathComponent("absent.jsonl").path,
            ]
        }

        /// The Claude Code payload for the same write, in a session of its own so the two runs' marks never meet.
        func claude(_ path: String, content: String) -> [String: Any] {
            ["session_id": "claude-session", "cwd": repo.path, "hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": ["file_path": path, "content": content]]
        }

        func run(_ payload: [String: Any], agent: String? = "cursor") throws -> (status: Int32, printed: String) {
            try run(stdin: JSONSerialization.data(withJSONObject: payload), agent: agent)
        }

        /// Runs this build's `sift post-tool-use`, with `--agent` where one is given, on `stdin`: its exit status and what it printed.
        func run(stdin: Data, agent: String? = "cursor", disabled: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, printed: String) {
            try Self.run(stdin: stdin, agent: agent, disabled: disabled, in: repo, home: home, sourceLocation: sourceLocation)
        }

        /// The same run, from `directory`, with `home` as its home and advice directory.
        static func run(
            stdin: Data,
            agent: String?,
            disabled: Bool = false,
            in directory: URL,
            home: URL,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> (status: Int32, printed: String) {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["post-tool-use"] + (agent.map { ["--agent", $0] } ?? [])
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
            environment["SIFT_NO_ADVICE"] = disabled ? "1" : nil
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
