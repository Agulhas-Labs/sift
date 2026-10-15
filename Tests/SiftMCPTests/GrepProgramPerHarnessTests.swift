//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// What a recursive search passes over follows the grep the calling harness's shell runs: Claude Code's `ugrep` skips the version-control directories and sift's binary database, and the system grep that Cursor's and Codex's shells run reads both.
@Suite(.temporaryDirectories)
struct GrepProgramPerHarnessTests {
    /// A sweep of an indexed repository, whose database names the type, is answered for Claude Code and let through for Cursor and Codex, whose grep reports a match in the database.
    @Test
    func aSweepPastTheDatabaseIsAnsweredOnlyForClaudeCode() async throws {
        let scene = try CursorPreToolUseTests.Scene()
        try MCPTestRepo.add(["Sources/App/Gizmo.swift": NoStoreSweepTests.gizmo, "\(NoStoreSweepTests.shelf)/Shop.swift": NoStoreSweepTests.shop()], to: scene.repo)
        try await SiftEngine(directory: scene.repo, registry: nil).ensureFresh()
        #expect(FileManager.default.fileExists(atPath: SiftPaths.cache(in: scene.repo).appendingPathComponent(SiftPaths.indexFileName).path))
        let command = "grep -rnw Gizmo ."

        let claude = try scene.run(scene.claude("Bash", ["command": command]), agent: nil)
        let cursor = try scene.run(scene.cursor("Shell", ["command": command, "cwd": ""]))
        var codexPayload = scene.claude("Bash", ["command": command])
        codexPayload["turn_id"] = "00000000-0000-7000-8000-000000000002"
        codexPayload["session_id"] = "codex-session"
        let codex = try scene.run(codexPayload, agent: nil)

        let specific = try #require(CursorPreToolUseTests.object(claude.printed)["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecision"] as? String == "deny")
        #expect((specific["permissionDecisionReason"] as? String)?.contains("where Gizmo") == true)
        for (harness, run) in [("cursor", cursor), ("codex", codex)] {
            #expect(run.status == 0, "\(harness)")
            #expect(run.printed.isEmpty, "\(harness) printed \(run.printed)")
        }
    }

    /// The system grep descends into every version-control directory, a names search's included; `ugrep` passes over every one of them for every search.
    @Test(arguments: [false, true])
    func theSystemGrepReadsEveryVersionControlDirectory(skipsCache: Bool) throws {
        let root = try TemporaryDirectory.make("program-walk").appendingPathComponent("program-walk")
        for (path, text) in [(".git/COMMIT_EDITMSG", "Depot lands\n"), (".hg/last-message.txt", "Depot\n"), ("Sources/A.swift", "let Depot = 1\n")] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        let ugrep = try Self.printedFiles(in: root, skipsCache: skipsCache, program: .ugrep)
        let system = try Self.printedFiles(in: root, skipsCache: skipsCache, program: .system)

        #expect(ugrep == ["Sources/A.swift"])
        #expect(system == [".git/COMMIT_EDITMSG", ".hg/last-message.txt", "Sources/A.swift"])
    }

    /// A match in sift's database is one the system grep reports, so a search finding one is left undecided under it; `ugrep` prints nothing from the database.
    @Test
    func aMatchInTheDatabaseIsUndecidedUnderTheSystemGrep() throws {
        let root = try TemporaryDirectory.make("program-store").appendingPathComponent("program-store")
        let cache = root.appendingPathComponent(SiftPaths.directoryName)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try Data("SQLite format 3\u{0}Depot\n".utf8).write(to: cache.appendingPathComponent(SiftPaths.indexFileName))
        try Data("let Depot = 1\n".utf8).write(to: root.appendingPathComponent("Sources/A.swift"))
        let search = try #require(ShellGrep(arguments: ["-rn", "Depot", "."]))

        #expect(try Self.printedFiles(in: root, skipsCache: false, program: .ugrep) == ["Sources/A.swift"])
        guard case .undecided = search.measured(in: root.path, program: .system).outcome else {
            Issue.record("expected the search left undecided, got \(search.measured(in: root.path, program: .system).outcome)")
            return
        }
    }

    /// The files of the lines a search of `.` for the type prints in `root`, below the root.
    private static func printedFiles(in root: URL, skipsCache: Bool, program: ShellGrep.Program, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String] {
        let measured = try #require(ShellGrep(arguments: ["-rn", "Depot", "."]), sourceLocation: sourceLocation).measured(in: root.path, skipsCache: skipsCache, program: program)
        guard case let .printed(lines) = measured.outcome else {
            Issue.record("expected the search worked out, got \(measured.outcome)", sourceLocation: sourceLocation)
            return []
        }
        let name = root.lastPathComponent
        return Array(Set(lines.map { $0.file.components(separatedBy: "/\(name)/").last ?? $0.file })).sorted()
    }
}
