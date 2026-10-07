//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP
import Testing

/// A Codex `apply_patch` made from a folder above several checkouts: each file is judged against the repository that holds it, as the `Write` of that file alone would be, whichever file of the patch comes first.
@Suite(.temporaryDirectories)
struct CodexPatchAcrossRepositoriesTests {
    typealias Scene = CursorPostToolUseTests.Scene

    /// A near duplicate in the second repository draws its nudge though the patch opens with a comment-only edit in the first.
    @Test func aNearDuplicateInTheSecondRepositoryDrawsItsNudge() async throws {
        let folder = try await Folder()
        try folder.restock()
        let patch = Folder.xyloComment + Folder.restockSection

        let codex = try folder.run(folder.codex(patch))

        #expect(codex.status == 0)
        #expect(codex.printed.contains("hookSpecificOutput") && codex.printed.contains("restock"), "\(codex.printed)")
    }

    /// A file no repository holds, first in the patch, is left out, and the near duplicate after it still draws the nudge.
    @Test func aFileOutsideEveryRepositoryDoesNotSilenceTheRest() async throws {
        let folder = try await Folder()
        try folder.restock()
        try "struct Loose {}\n".write(to: folder.parent.appendingPathComponent("Loose.swift"), atomically: true, encoding: .utf8)
        let patch = "*** Add File: Loose.swift\n+struct Loose {}\n" + Folder.restockSection

        let codex = try folder.run(folder.codex(patch))

        #expect(codex.status == 0)
        #expect(codex.printed.contains("hookSpecificOutput") && codex.printed.contains("restock"), "\(codex.printed)")
    }

    /// A broken file added in the second repository is blocked exactly as a `Write` of it is, its path relative to its own repository, though the patch opens in the first.
    @Test func aBrokenFileInTheSecondRepositoryIsBlockedAsAWriteOfItIs() async throws {
        let folder = try await Folder()
        let broken = folder.depot.appendingPathComponent("Sources/App/Broken.swift")
        try Scene.broken.write(to: broken, atomically: true, encoding: .utf8)
        let write = ["session_id": "claude-session", "cwd": folder.depot.path, "hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": ["file_path": broken.path, "content": Scene.broken]] as [String: Any]
        let claude = try Scene.run(stdin: JSONSerialization.data(withJSONObject: write), agent: nil, in: folder.depot, home: folder.home)
        #expect(claude.printed.contains("\"decision\":\"block\""), "\(claude.printed)")

        let codex = try folder.run(folder.codex(Folder.xyloComment + "*** Add File: Depot/Sources/App/Broken.swift\n+struct Catalogue {\n+    func count( {\n+}\n"))

        #expect(codex.status == 0)
        #expect(codex.printed == claude.printed)
    }
}

extension CodexPatchAcrossRepositoriesTests {
    /// A folder holding two indexed checkouts: `Xylo`, and `Depot`, whose `Depot.stock()` makes four calls beside a catalogue to write.
    struct Folder {
        static var xyloComment: String {
            "*** Update File: Xylo/Sources/App/Xylo.swift\n@@\n+/// Played daily.\n /// The test type.\n"
        }

        static var restockSection: String {
            "*** Update File: Depot/Sources/App/Catalogue.swift\n@@\n         1\n     }\n+\n+    func restock() -> Int {\n+        let crates = load()\n"
                + "+        let weight = weigh(crates)\n+        label(crates, weight)\n+        return ship(crates)\n+    }\n }\n"
        }

        let parent: URL
        let xylo: URL
        let depot: URL
        let home: URL

        init() async throws {
            let folder = try TemporaryDirectory.make("checkouts")
            xylo = try MCPTestRepo.make(at: folder.appendingPathComponent("Xylo"), declaring: "Xylo")
            depot = try MCPTestRepo.make(at: folder.appendingPathComponent("Depot"), declaring: "Depot")
            parent = depot.deletingLastPathComponent()
            let stock = "struct Depot {\n    func stock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
            try MCPTestRepo.add(["Sources/App/Depot.swift": stock, "Sources/App/Catalogue.swift": Scene.catalogueSource], to: depot)
            try await SiftEngine(directory: xylo, registry: nil).ensureFresh()
            try await SiftEngine(directory: depot, registry: nil).ensureFresh()
            home = try TemporaryDirectory.make("codex-home")
            try ("/// Played daily.\n/// The test type.\nstruct Xylo {\n    let one = 1\n    func go() {}\n}\n")
                .write(to: xylo.appendingPathComponent("Sources/App/Xylo.swift"), atomically: true, encoding: .utf8)
        }

        /// Writes the catalogue with `restock()` added, as the patch's update leaves it.
        func restock() throws {
            try Scene.restocked.write(to: depot.appendingPathComponent("Sources/App/Catalogue.swift"), atomically: true, encoding: .utf8)
        }

        /// Codex's `PostToolUse` payload for an `apply_patch` of `sections`, made from the folder above both checkouts.
        func codex(_ sections: String) -> [String: Any] {
            [
                "hook_event_name": "PostToolUse", "tool_name": "apply_patch",
                "tool_input": ["command": "*** Begin Patch\n" + sections + "*** End Patch"],
                "tool_response": "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess.\n",
                "cwd": parent.path, "session_id": "codex-session", "tool_use_id": "t1",
            ]
        }

        func run(_ payload: [String: Any]) throws -> (status: Int32, printed: String) {
            try Scene.run(stdin: JSONSerialization.data(withJSONObject: payload), agent: nil, in: parent, home: home)
        }
    }
}
