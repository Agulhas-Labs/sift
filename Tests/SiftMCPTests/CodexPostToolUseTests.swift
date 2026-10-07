//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// `sift post-tool-use` as the Codex registration runs it, with no `--agent`, driven through the built binary with Codex's `PostToolUse` payload for an `apply_patch` in the shape a probe of Codex CLI 0.159.2 captured: each Swift file the patch adds or updates is judged as the Claude Code `Write` of it would be, and the patch draws one answer.
///
/// The capture was of an `*** Add File:` section. The `*** Update File:`, `*** Delete File:` and `*** Move to:` headers and the `@@` hunk line are assumptions taken from Codex's documented patch grammar, not from a capture.
@Suite(.temporaryDirectories)
struct CodexPostToolUseTests {
    typealias Scene = CursorPostToolUseTests.Scene

    /// An added Swift file that does not parse is blocked with the reason a Claude Code `Write` of it draws.
    @Test func anAddLeavingSwiftUnparseableIsBlockedAsAWriteOfItIs() async throws {
        let scene = try await Scene()
        try Self.broken.write(toFile: Self.path("Broken.swift", in: scene), atomically: true, encoding: .utf8)
        let claude = try scene.run(scene.claude(Self.path("Broken.swift", in: scene), content: Self.broken), agent: nil)
        #expect(claude.printed.contains("\"decision\":\"block\""), "\(claude.printed)")

        let codex = try scene.run(Self.codex(Self.add("Broken.swift", Self.broken), in: scene), agent: nil)

        #expect(codex.status == 0)
        #expect(codex.printed == claude.printed)
    }

    /// An update adding a near duplicate draws the nudge a Claude Code `Write` of the same file draws.
    @Test func anUpdateAddingANearDuplicateDrawsTheNudgeAWriteOfItDraws() async throws {
        let scene = try await Scene()
        try Scene.restocked.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        let claude = try scene.run(scene.claude(scene.catalogue, content: Scene.restocked), agent: nil)
        #expect(claude.printed.contains("hookSpecificOutput"), "\(claude.printed)")
        try await scene.setBack()

        let codex = try scene.run(Self.codex(Self.restock, in: scene), agent: nil)

        #expect(codex.status == 0)
        #expect(codex.printed == claude.printed)
    }

    /// A patch touching several files draws one answer: the block for the first file left unparseable, though an earlier file would draw a nudge and a later one a block of its own.
    @Test func aPatchOfSeveralFilesDrawsOneBlockForTheFirstBrokenFile() async throws {
        let scene = try await Scene()
        try Scene.restocked.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        try await scene.setBack()
        try Self.broken.write(toFile: Self.path("Broken.swift", in: scene), atomically: true, encoding: .utf8)
        try Self.broken.write(toFile: Self.path("Snapped.swift", in: scene), atomically: true, encoding: .utf8)
        let patch = Self.restock + Self.add("Broken.swift", Self.broken) + Self.add("Snapped.swift", Self.broken)

        let codex = try scene.run(Self.codex(patch, in: scene), agent: nil)

        #expect(codex.status == 0)
        #expect(codex.printed.split(separator: "\n").count == 1, "\(codex.printed)")
        let reason = try #require(CursorPostToolUseTests.object(codex.printed)["reason"] as? String)
        #expect(reason.contains("Broken.swift"), "\(reason)")
        #expect(!reason.contains("Snapped.swift"), "\(reason)")
    }

    /// Every patch this does not read, or reads as leaving nothing to check, prints nothing and exits 0; each is a variant of an add that would be blocked.
    @Test(arguments: Unread.allCases)
    func aPatchThisDoesNotJudgeDrawsNothing(unread: Unread) async throws {
        let scene = try await Scene()
        try Self.broken.write(toFile: Self.path("Broken.swift", in: scene), atomically: true, encoding: .utf8)

        let run = try scene.run(stdin: unread.stdin(scene), agent: nil, disabled: unread == .adviceOff)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A near duplicate in the second file of a patch draws the nudge though the first file is updated too: bringing the first file's record up to date must not make the second file's new function look as if the index held it before.
    @Test func aNearDuplicateAfterAnotherUpdatedFileStillDrawsTheNudge() async throws {
        let scene = try await Scene()
        try Scene.restocked.write(toFile: scene.catalogue, atomically: true, encoding: .utf8)
        try await scene.setBack()
        try ("/// Stocked daily.\n" + Self.depot).write(toFile: Self.path("Depot.swift", in: scene), atomically: true, encoding: .utf8)
        let patch = "*** Update File: Sources/App/Depot.swift\n@@\n+/// Stocked daily.\n struct Depot {\n" + Self.restock

        let codex = try scene.run(Self.codex(patch, in: scene), agent: nil)

        #expect(codex.status == 0)
        #expect(codex.printed.contains("hookSpecificOutput") && codex.printed.contains("restock"), "\(codex.printed)")
    }

    /// `Depot.swift` as the scene indexes it.
    static var depot: String {
        "struct Depot {\n    func stock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
    }

    static var broken: String {
        "struct Broken {\n"
    }

    /// The update adding `Catalogue.restock()`, whose body is `Depot.stock()`'s.
    static var restock: String {
        "*** Update File: Sources/App/Catalogue.swift\n@@\n         1\n     }\n+\n+    func restock() -> Int {\n+        let crates = load()\n"
            + "+        let weight = weigh(crates)\n+        label(crates, weight)\n+        return ship(crates)\n+    }\n }\n"
    }

    /// The section adding `content` at `Sources/App/<name>`.
    static func add(_ name: String, _ content: String) -> String {
        "*** Add File: Sources/App/\(name)\n" + content.split(separator: "\n").map { "+\($0)\n" }.joined()
    }

    static func path(_ name: String, in scene: Scene) -> String {
        scene.repo.appendingPathComponent("Sources/App/\(name)").path
    }

    /// Codex's `PostToolUse` payload for an `apply_patch` of `sections`, its fields as the probe captured them: the path relative to `cwd`, the response a string opening with the exit code.
    static func codex(_ sections: String, in scene: Scene, exitCode: Int = 0) -> [String: Any] {
        [
            "hook_event_name": "PostToolUse", "tool_name": "apply_patch",
            "tool_input": ["command": "*** Begin Patch\n" + sections + "*** End Patch"],
            "tool_response": "Exit code: \(exitCode)\nWall time: 0 seconds\nOutput:\nSuccess. Updated the following files:\nA Sources/App/Broken.swift\n",
            "cwd": scene.repo.path, "session_id": "codex-session", "tool_use_id": "t1",
        ]
    }
}

extension CodexPostToolUseTests {
    /// A variant of an `apply_patch` adding a broken Swift file that must draw silence.
    enum Unread: String, CaseIterable {
        case failedPatch
        case responseNotText
        case notSwift
        case deleted
        case moved
        case noSession
        case adviceOff

        func stdin(_ scene: Scene) throws -> Data {
            var payload = CodexPostToolUseTests.codex(CodexPostToolUseTests.add("Broken.swift", CodexPostToolUseTests.broken), in: scene)
            switch self {
            case .failedPatch:
                payload = CodexPostToolUseTests.codex(CodexPostToolUseTests.add("Broken.swift", CodexPostToolUseTests.broken), in: scene, exitCode: 1)
            case .responseNotText:
                payload["tool_response"] = ["output": "Success."]
            case .notSwift:
                payload["tool_input"] = ["command": "*** Begin Patch\n*** Add File: notes.txt\n+hi\n*** End Patch"]
            case .deleted:
                payload["tool_input"] = ["command": "*** Begin Patch\n*** Delete File: Sources/App/Broken.swift\n*** End Patch"]
            case .moved:
                payload["tool_input"] = ["command": "*** Begin Patch\n*** Update File: Sources/App/Broken.swift\n*** Move to: Sources/App/Moved.swift\n@@\n+struct Moved {}\n*** End Patch"]
            case .noSession:
                payload["session_id"] = nil
            case .adviceOff:
                break
            }
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }
}
