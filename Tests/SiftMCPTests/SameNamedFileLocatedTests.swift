//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The audit's scan credits a digest to the one file its target resolved to, in the file's own repository, as the advice hook does: a window of a same-named file elsewhere stays cold where the hook answers it in place.
@Suite(.temporaryDirectories)
struct SameNamedFileLocatedTests {
    /// A repository holding two files named `Alpha.swift`: the fixture's own under `Sources/App`, declaring `Alpha`, and another at the root.
    private static func repositoryWithTwoAlphas() throws -> URL {
        let root = try MCPTestRepo.make()
        try "struct Beta {}\n".write(to: root.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// A digest answer's header as the server prints it for a file or a type.
    private static func answer(_ header: String) -> String {
        "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\n\(header)\n    let one = 1  :3\n"
    }

    /// Each digest locates the file its answer resolved it to, and a window of the other file of that name is cold.
    @Test(arguments: [
        ("Alpha.swift", "Alpha.swift — module: App", "Alpha.swift", "Sources/App/Alpha.swift"),
        ("Alpha", "Alpha — App — Sources/App/Alpha.swift:2-5", "Sources/App/Alpha.swift", "Alpha.swift"),
        ("Sources/App/Alpha.swift", "Sources/App/Alpha.swift — module: App", "Sources/App/Alpha.swift", "Alpha.swift"),
    ])
    func aDigestLocatesOnlyTheFileItResolvedTo(target: String, header: String, located: String, other: String) throws {
        let here = try Self.repositoryWithTwoAlphas()
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": target], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: Self.answer(header)),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p \(other)"], cwd: here.path),
                TranscriptFixture.toolUse("Bash", id: "w2", input: ["command": "sed -n 1,3p \(located)"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .cold(file: other, missed: nil), .guided(file: located)])
    }

    /// A shell digest is credited the same way, by the file its output named, and so is a whole read after it: of the digested file it is the read the digest was for, of the other file a first read.
    @Test
    func aShellDigestLocatesOnlyTheFileItsOutputNamed() throws {
        let here = try Self.repositoryWithTwoAlphas()
        let other = here.appendingPathComponent("Sources/App/Alpha.swift").path
        let digested = here.appendingPathComponent("Alpha.swift").path
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: Self.answer("Alpha.swift — module: App")),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": other], cwd: here.path),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": digested], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups.dropFirst().first == .cold(file: "Sources/App/Alpha.swift", missed: nil))
        #expect(lookups.dropFirst(2).first != .readWholeAfterDigest(file: other))
        #expect(lookups.last == .readWholeAfterDigest(file: digested))
    }

    /// Located is keyed by the repository the read file is in, not the one the call was made from: a digest answered from another repository locates that repository's file, and one answered from the caller's own never locates another repository's file of the same path.
    @Test(arguments: [true, false])
    func aReadIsJudgedAgainstItsOwnRepository(digestAnsweredThere: Bool) throws {
        let here = try MCPTestRepo.make()
        let there = try MCPTestRepo.make()
        let read = there.appendingPathComponent("Sources/App/Alpha.swift").path
        var input: [String: Any] = ["target": "Sources/App/Alpha.swift"]
        if digestAnsweredThere {
            input["root"] = there.path
        }
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: input, cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: Self.answer("Sources/App/Alpha.swift — module: App")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": read, "offset": 2, "limit": 3], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups.last == (digestAnsweredThere ? .guided(file: read) : .cold(file: read, missed: nil)))
    }

    /// The renderer shows no file at all where several indexed files end in the target — its own "ambiguous" answer — so the scan must not credit either candidate either: a window of both stays cold.
    @Test
    func anAmbiguousDigestLocatesNeitherCandidate() throws {
        let here = try MCPTestRepo.make()
        for file in ["Sources/A/App/Shell.swift", "Sources/B/App/Shell.swift"] {
            let url = here.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct Shell {}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let ambiguous = """
        App/Shell.swift is ambiguous — 2 indexed files end in it; digest one of these exact targets:
          digest Sources/A/App/Shell.swift
          digest Sources/B/App/Shell.swift
        """
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "App/Shell.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: ambiguous),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Sources/A/App/Shell.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Bash", id: "w2", input: ["command": "sed -n 1,3p Sources/B/App/Shell.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(
            lookups == [
                .indexed,
                .cold(file: "Sources/A/App/Shell.swift", missed: nil),
                .cold(file: "Sources/B/App/Shell.swift", missed: nil),
            ]
        )
    }

    /// A type declared in two files is ambiguous to the renderer, which shows neither, and the hook credits neither: a digest of the type, or of one of its members, leaves a window of each file cold here too.
    @Test(arguments: ["Shell", "Shell.go"])
    func anAmbiguousTypeDigestLocatesNeitherFile(target: String) throws {
        let here = try MCPTestRepo.make()
        for file in ["Sources/A/Shell.swift", "Sources/B/Shell.swift"] {
            let url = here.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct Shell {\n    func go() {}\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let ambiguous = """
        \(target) is ambiguous — 2 declarations; digest one of these exact targets:
          digest A.\(target) — struct — Sources/A/Shell.swift:1-3
          digest B.\(target) — struct — Sources/B/Shell.swift:1-3
        """
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": target], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: ambiguous),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Sources/A/Shell.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Bash", id: "w2", input: ["command": "sed -n 1,3p Sources/B/Shell.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(
            lookups == [
                .indexed,
                .cold(file: "Sources/A/Shell.swift", missed: nil),
                .cold(file: "Sources/B/Shell.swift", missed: nil),
            ]
        )
    }

    /// A member's digest locates the file its answer printed the member in, the one named for its type, as the hook resolves that type — and a same-named file elsewhere stays cold, as does a whole read, which the member's body never stood for.
    @Test
    func aMemberDigestLocatesTheFileDeclaringItsType() throws {
        let here = try Self.repositoryWithTwoAlphas()
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Alpha.go(_:)"], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: Self.answer("App.Alpha.go(_:) — func — Sources/App/Alpha.swift:4")),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Bash", id: "w2", input: ["command": "sed -n 1,3p Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": here.appendingPathComponent("Sources/App/Alpha.swift").path], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [
            .indexed,
            .cold(file: "Alpha.swift", missed: nil),
            .guided(file: "Sources/App/Alpha.swift"),
            .cold(file: here.appendingPathComponent("Sources/App/Alpha.swift").path, missed: nil),
        ])
    }

    /// A module digest locates each file it lists under a heading, by its path: a window of a listed file is guided, and one of a same-named file it did not list stays cold.
    @Test
    func aModuleDigestLocatesTheFilesItLists() throws {
        let here = try Self.repositoryWithTwoAlphas()
        let listing = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\nmodule App — 1 top-level declaration\n\nSources/App/Alpha.swift:\n  struct Alpha  :2-5\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "App"], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: listing),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolUse("Bash", id: "w2", input: ["command": "sed -n 1,3p Sources/App/Alpha.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .cold(file: "Alpha.swift", missed: nil), .guided(file: "Sources/App/Alpha.swift")])
    }

    /// A digest answered in a checkout since removed — an agent's worktree inside the repository, its directory left behind — still locates the file it named there, spelled from the directory the call was made in.
    @Test
    func aDigestFromAGoneCheckoutLocatesItsFileThere() throws {
        let here = try MCPTestRepo.make()
        // Its directory is left behind without its checkout, so the repository around it is the one found.
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Alpha"], cwd: gone),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: Self.answer("Alpha — App — Sources/App/Alpha.swift:2-5")),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: gone),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift")])
    }

    /// Where a digest's answer names no file, the scan asks what the hook asks: a path target locates the file at that path, or the one file ending in it, and a type target the file named for it that the index resolves it to — and nothing where there is no index to ask, since a stem alone is not identity.
    @Test(arguments: [
        ("Sources/App/Alpha.swift", false),
        ("App/Alpha.swift", false),
        ("Alpha", true),
        ("Alpha", false),
    ])
    func aDigestWhoseAnswerNamesNoFileLocatesWhatTheHookWould(target: String, indexed: Bool) async throws {
        let here = try MCPTestRepo.make()
        if indexed {
            try await SiftEngine(directory: here).ensureFresh()
        }
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": target], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: Self.answer("struct Alpha  :2-5")),
                TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n 1,3p Sources/App/Alpha.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )
        let credited = target.hasSuffix(".swift") || indexed
        let window = "Sources/App/Alpha.swift"

        #expect(lookups == [.indexed, credited ? .guided(file: window) : .cold(file: window, missed: nil)])
    }
}
