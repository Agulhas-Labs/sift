//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// `sift pre-tool-use --agent cursor`, driven through the built binary with Cursor's `preToolUse` payloads in the shapes a probe of a real Cursor recorded: the same decisions as the Claude Code registration, printed in Cursor's schema, and nothing at all for a payload it cannot read.
@Suite(.temporaryDirectories)
struct CursorPreToolUseTests {
    /// A refusal is Cursor's deny, carrying the reason the Claude Code registration gives the same call in `user_message`, the field the model reads.
    @Test(arguments: Refused.allCases)
    func aRefusalCarriesTheClaudeReasonInCursorsShape(refused: Refused) throws {
        let scene = try Scene()
        let claude = try scene.run(scene.claude(refused.claudeTool, refused.claudeInput(scene)), agent: nil)
        let specific = try #require(Self.object(claude.printed)["hookSpecificOutput"] as? [String: Any])
        let reason = try #require(specific["permissionDecisionReason"] as? String)

        let cursor = try scene.run(scene.cursor(refused.cursorTool, refused.cursorInput(scene), session: "cursor-\(refused)"))
        let object = try Self.object(cursor.printed)

        #expect(cursor.status == 0)
        #expect(Set(object.keys) == ["permission", "user_message", "agent_message"])
        #expect(object["permission"] as? String == "deny")
        #expect(object["user_message"] as? String == reason)
        #expect(object["agent_message"] as? String == reason)
    }

    /// The probed calls that are no lookup (and an index call that already names its root) run untouched: nothing printed, exit 0.
    @Test(arguments: LetThrough.allCases)
    func aCallThatIsNoLookupDrawsNothing(call: LetThrough) throws {
        let scene = try Scene()
        let run = try scene.run(scene.cursor(call.tool, call.input(scene)))

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// Every payload this cannot read prints nothing and exits 0, each a variant of a call the readable payload refuses.
    @Test(arguments: Unread.allCases)
    func aPayloadThisCannotReadDrawsNothing(unread: Unread) throws {
        let scene = try Scene()
        let run = try scene.run(stdin: unread.stdin(scene))

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// An index call with no root is run with the caller's repository as its root, the whole input sent back.
    @Test(arguments: [("MCP:digest", ["target": "Sources/App/Depot.swift"]), ("MCP:where", ["symbol": "Depot"]), ("MCP:search", ["query": "kind:struct"])])
    func aRootlessIndexCallIsRootedAtTheWorkspace(tool: String, input: [String: String]) throws {
        let scene = try Scene()
        let run = try scene.run(scene.cursor(tool, input))
        let object = try Self.object(run.printed)
        let root = try #require(CallerRoot.root(forCallerIn: scene.repo.path))

        #expect(run.status == 0)
        #expect(Set(object.keys) == ["updated_input"])
        let amended = try #require(object["updated_input"] as? [String: String])
        #expect(amended == input.merging(["root": root]) { $1 })
    }

    /// A call spelled like one of this server's whose arguments this server's tool does not take is another server's, and is left alone.
    @Test(arguments: [["target": "A.swift", "format": "json"], ["path": "A.swift"], [:]])
    func anotherServersDigestIsLeftAlone(input: [String: String]) throws {
        let scene = try Scene()
        let run = try scene.run(scene.cursor("MCP:digest", input))

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    @Test
    func cursorsNameForAnIndexCallIsReadOnlyWithArgumentsThisServerTakes() {
        #expect(IndexToolName.tool(namedByCursor: "MCP:digest", input: ["target": "A.swift", "root": "/r"]) == "digest")
        #expect(IndexToolName.tool(namedByCursor: "MCP:digest", input: ["targets": ["A.swift"]]) == "digest")
        #expect(IndexToolName.tool(namedByCursor: "MCP:where", input: ["symbol": "Depot", "refs": true]) == "where")
        #expect(IndexToolName.tool(namedByCursor: "MCP:strings", input: ["query": "Save"]) == "strings")
        #expect(IndexToolName.tool(namedByCursor: "MCP:digest", input: ["all": true]) == nil)
        #expect(IndexToolName.tool(namedByCursor: "MCP:where", input: ["name": "Depot"]) == nil)
        #expect(IndexToolName.tool(namedByCursor: "MCP:search", input: ["query": 3]) == nil)
        #expect(IndexToolName.tool(namedByCursor: "MCP:similar", input: ["target": "A.swift"]) == nil)
        #expect(IndexToolName.tool(namedByCursor: "mcp__sift__digest", input: ["target": "A.swift"]) == nil)
        #expect(IndexToolName.tool(named: "MCP:digest") == nil)
    }

    @Test
    func cursorsDenialHasExactlyItsThreeKeys() {
        #expect(CursorHookOutput.preToolUseDenial(message: "use digest") == #"{"agent_message":"use digest","permission":"deny","user_message":"use digest"}"#)
        #expect(CursorHookOutput.preToolUseAmendment(input: ["target": "A.swift", "root": "/r"]) == #"{"updated_input":{"root":"/r","target":"A.swift"}}"#)
    }
}

extension CursorPreToolUseTests {
    enum Refused: String, CaseIterable {
        case build, documentRead

        var cursorTool: String {
            self == .build ? "Shell" : "Read"
        }

        var claudeTool: String {
            self == .build ? "Bash" : "Read"
        }

        func cursorInput(_ scene: Scene) -> [String: Any] {
            self == .build ? ["command": "swift build", "cwd": "", "timeout": 30000] : ["file_path": scene.document]
        }

        func claudeInput(_ scene: Scene) -> [String: Any] {
            self == .build ? ["command": "swift build"] : ["file_path": scene.document]
        }
    }

    enum LetThrough: String, CaseIterable {
        case shell, read, grep, write, rootedDigest

        var tool: String {
            switch self {
            case .shell: "Shell"
            case .read: "Read"
            case .grep: "Grep"
            case .write: "Write"
            case .rootedDigest: "MCP:digest"
            }
        }

        func input(_ scene: Scene) -> [String: Any] {
            switch self {
            case .shell: ["command": "echo hello", "cwd": "", "timeout": 30000]
            case .read: ["file_path": scene.repo.appendingPathComponent("notes.txt").path]
            case .grep: ["pattern": "struct", "file_path": scene.repo.appendingPathComponent("Sources/App/Depot.swift").path]
            case .write: ["file_path": scene.repo.appendingPathComponent("created.txt").path, "content": "hi\n"]
            case .rootedDigest: ["target": "Sources/App/Depot.swift", "root": scene.repo.path]
            }
        }
    }

    enum Unread: String, CaseIterable {
        case garbage, noRoots, emptyRoots, relativeRoot, emptyInput, unknownTool, claudeSpelling, unprobedKey, otherEvent

        func stdin(_ scene: Scene) throws -> Data {
            guard self != .garbage else { return Data("not json {".utf8) }
            var payload = scene.cursor("Shell", ["command": "swift build", "cwd": "", "timeout": 30000])
            switch self {
            case .garbage: break
            case .noRoots: payload["workspace_roots"] = nil
            case .emptyRoots: payload["workspace_roots"] = [String]()
            case .relativeRoot: payload["workspace_roots"] = ["repo"]
            case .emptyInput: payload["tool_input"] = [String: Any]()
            case .unknownTool: payload["tool_name"] = "Delete"
            case .claudeSpelling: payload["tool_name"] = "Bash"
            case .unprobedKey: payload["tool_input"] = ["command": "swift build", "cwd": "", "timeout": 30000, "is_background": true]
            case .otherEvent: payload["hook_event_name"] = "postToolUse"
            }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }

    /// A git repository holding a package, a Swift file and a document over the outline floor, and a home, advice directory and usage log of the test's own.
    struct Scene {
        let repo: URL
        let home: URL
        let document: String

        init() throws {
            repo = try TemporaryDirectory.make("cursor-repo")
            home = try TemporaryDirectory.make("cursor-home")
            let git = try Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["init", "-q", repo.path])
            git.waitUntilExit()
            try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
            try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\")\n"
                .write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "struct Depot {\n    let name: String\n}\n".write(to: repo.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
            try "notes\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            document = repo.appendingPathComponent("Guide.md").path
            let body = (1 ... 12).map { "## Part \($0)\n\n" + String(repeating: "A line of prose about this part of the guide.\n", count: 20) }
            try ("# Guide\n\n" + body.joined(separator: "\n")).write(toFile: document, atomically: true, encoding: .utf8)
        }

        /// A Cursor `preToolUse` payload for `tool` with `input`, its common fields as a probe recorded them.
        func cursor(_ tool: String, _ input: [String: Any], session: String = "cursor-session") -> [String: Any] {
            [
                "conversation_id": "c1", "generation_id": "g1", "model": "default", "tool_name": tool, "tool_input": input,
                "tool_use_id": "t1", "cwd": "", "session_id": session, "hook_event_name": "preToolUse", "cursor_version": "1.0",
                "workspace_roots": [repo.path], "transcript_path": home.appendingPathComponent("absent.jsonl").path,
            ]
        }

        /// The Claude Code payload for the same call.
        func claude(_ tool: String, _ input: [String: Any]) -> [String: Any] {
            ["session_id": "claude-session", "cwd": repo.path, "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input, "tool_use_id": "t1"]
        }

        func run(_ payload: [String: Any], agent: String? = "cursor") throws -> (status: Int32, printed: String) {
            try run(stdin: JSONSerialization.data(withJSONObject: payload), agent: agent)
        }

        /// Runs this build's `sift pre-tool-use`, with `--agent` where one is given, on `stdin`: its exit status and what it printed.
        func run(stdin: Data, agent: String? = "cursor", sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, printed: String) {
            let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["pre-tool-use"] + (agent.map { ["--agent", $0] } ?? [])
            process.currentDirectoryURL = repo
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["CFFIXED_USER_HOME"] = home.path
            environment["SIFT_HOME"] = home.appendingPathComponent("sift").path
            // A suite run under a live harness has that harness among the hook's ancestors, and its real server on record.
            environment["SIFT_SERVER_LOG"] = home.appendingPathComponent("server.jsonl").path
            environment["SIFT_ADVICE_DIR"] = home.appendingPathComponent("advice").path
            environment["SIFT_USAGE_LOG"] = home.appendingPathComponent("usage.jsonl").path
            environment["SIFT_NO_ADVICE"] = nil
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            // The user's own Claude Code settings decide whether a build is rewritten or refused, so the child reads an empty configuration instead.
            environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent("claude").path
            environment["CLAUDE_PROJECT_DIR"] = nil
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

    static func object(_ printed: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let data = Data(printed.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "printed \(printed)", sourceLocation: sourceLocation)
    }
}
