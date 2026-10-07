//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The audit's scan still credits a digest to the file it did locate wherever the answer's text or the transcript says which file that was, so holding a digest to its exact file drops only the same-named and ambiguous windows.
@Suite(.temporaryDirectories)
struct ScanExactLocatedTests {
    /// A checkout removed so completely that no repository is found around it: a directory the scan can ask nothing of.
    private static func goneCheckout() throws -> String {
        try TemporaryDirectory.make("gone").appendingPathComponent("agent-gone").path
    }

    /// A digest of several files names each after the first on a line opening with the renderer's part marker, and still locates that file.
    @Test
    func aLaterFileOfASeveralTargetDigestIsLocated() throws {
        let gone = try Self.goneCheckout()
        let answer = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Beta.swift — module: App\n    let one = 1  :3\n\n"
            + "\(SourcePassthrough.partMarker)Sources/App/Alpha.swift — module: App\n    let two = 2  :3\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["targets": ["Sources/App/Beta.swift", "Sources/App/Alpha.swift"]], cwd: gone),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: gone),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift")])
    }

    /// A shell digest run after a `cd` into a checkout since removed locates the file it named there, spelled from the directory it moved to rather than the one the line was run from.
    @Test
    func aShellDigestAfterACdIntoAGoneCheckoutLocatesItsFileThere() throws {
        let here = try MCPTestRepo.make()
        // Its directory is left behind without its checkout, so the repository around it is the one found.
        let gone = here.appendingPathComponent(".build/rev-gone").path
        try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
        let answer = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && sift digest Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift")])
    }

    /// A digest answered in a checkout since removed that sat outside the repository the line was run in — a scratch checkout — still locates the file it named there.
    @Test
    func aDigestFromAGoneCheckoutOutsideTheRepositoryLocatesItsFileThere() throws {
        let here = try MCPTestRepo.make()
        let gone = try Self.goneCheckout()
        let answer = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && sift digest Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift")])
    }

    /// A digest of a path whose answer names no file, in a checkout so completely gone that nothing can be asked, locates the file at that path from where it was asked, and not a same-named file elsewhere.
    @Test
    func aPathDigestWhoseAnswerNamesNoFileLocatesThatPath() throws {
        let gone = try Self.goneCheckout()
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest Sources/App/Alpha.swift | grep -n func"], cwd: gone),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: "4:    func one() -> Int  :4-6\n"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: gone),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": gone + "/Other/Sources/App/Alpha.swift", "offset": 1], cwd: gone),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift"), .cold(file: gone + "/Other/Sources/App/Alpha.swift", missed: nil)])
    }

    /// A shell digest run after a `cd` into a checkout since removed does not locate the same-named file of the repository the line was run in: its answer named that file relative to the removed checkout.
    @Test
    func aShellDigestInAGoneCheckoutDoesNotLocateTheLiveSameNamedFile() throws {
        let here = try MCPTestRepo.make()
        // Removed whole, as a worktree is, so nothing on disk is left to name its repository.
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        let answer = "tree: agent-gone  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        let live = here.appendingPathComponent("Sources/App/Alpha.swift").path
        try #require(FileManager.default.fileExists(atPath: live))
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && sift digest Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": live, "offset": 1], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .cold(file: live, missed: nil)])
    }

    /// A read the hook answered in place after a `cd` into a checkout since removed locates the file it named there, spelled from where the line moved rather than the directory it was run from.
    @Test
    func anInPlaceAnswerAfterACdIntoAGoneCheckoutLocatesItsFileThere() throws {
        let here = try MCPTestRepo.make()
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        let answer = "tree: repo (worktree agent-gone)  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        let reason = InPlaceAnswer.reason(calls: ["digest Sources/App/Alpha.swift"], answer: answer, source: nil, standsIn: "", wholeCommand: false).text
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && cat Sources/App/Alpha.swift; git status"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: true, text: "PreToolUse:Bash hook error: " + reason),
                TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": "cd \(gone) && sed -n 3,9p Sources/App/Alpha.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups.last == .guided(file: "Sources/App/Alpha.swift"))
    }

    /// A path digest after a `cd` into a checkout since removed, whose filtered answer names no file, locates that path spelled from where the line moved, though the live repository holds a file of the same name.
    @Test
    func aFilteredPathDigestInAGoneCheckoutLocatesThatPathThere() throws {
        let here = try MCPTestRepo.make()
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        try #require(FileManager.default.fileExists(atPath: here.appendingPathComponent("Sources/App/Alpha.swift").path))
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && sift digest Sources/App/Alpha.swift | tail -n +3"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: "    let one = 1  :3\n"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift")])
    }

    /// A type's digest in a checkout since removed, whose filtered answer names no file, locates the file named for that type there, and no other file of that checkout.
    @Test
    func aFilteredTypeDigestInAGoneCheckoutLocatesTheFileNamedForIt() throws {
        let gone = try Self.goneCheckout()
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest Alpha.one 2>&1 | tail -3"], cwd: gone),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: "    let one = 1  :3\n"),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift", "offset": 1], cwd: gone),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": gone + "/Sources/App/Beta.swift", "offset": 1], cwd: gone),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/Sources/App/Alpha.swift"), .cold(file: gone + "/Sources/App/Beta.swift", missed: nil)])
    }

    /// A path digest the renderer answered by serving the one indexed file of that name instead locates the file it served, and not the path it was asked for.
    @Test
    func aPathDigestServedFromAnotherDirectoryLocatesTheFileServed() throws {
        let here = try MCPTestRepo.make()
        let served = here.appendingPathComponent("Sources/App/Alpha.swift").path
        let answer = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\n"
            + "no indexed file at Sources/Other/Alpha.swift — served Sources/App/Alpha.swift, the one indexed file of that name\n"
            + "Sources/App/Alpha.swift — module: App\n    let one = 1  :3\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/Other/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": served, "offset": 1], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: served)])
    }

    /// A shell digest of a glob the shell expanded to several files locates each file its answer opens a part on, and no file the glob does not match.
    @Test(arguments: [(glob: "Sources/*/Alpha.swift", other: "Sources/Kit/Alpha.swift"), (glob: "'Sources/App/*.swift'", other: "Sources/App/Beta.swift")])
    func aGlobDigestLocatesEveryFileItsAnswerHeads(glob: String, other: String) throws {
        let gone = try Self.goneCheckout()
        let answer = "tree: repo  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift — module: App\n    let one = 1  :3\n\n"
            + "\(SourcePassthrough.partMarker)\(other) — module: App\n    let two = 2  :3\n"
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest \(glob)"], cwd: gone),
                TranscriptFixture.toolResult(id: "b1", isError: false, text: answer),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/" + other, "offset": 1], cwd: gone),
                TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": gone + "/Tests/App/Alpha.swift", "offset": 1], cwd: gone),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups == [.indexed, .guided(file: gone + "/" + other), .cold(file: gone + "/Tests/App/Alpha.swift", missed: nil)])
    }

    /// A window of a file in another repository is not dumped as located by an answer in the repository the call was made from that named a file of the same name.
    @Test
    func aWindowInAnotherRepositoryNamesNoLocatorFromTheCallersOwn() throws {
        let parent = try TemporaryDirectory.make("pair")
        let here = try MCPTestRepo.make(at: parent.appendingPathComponent("here"))
        let other = try MCPTestRepo.make(at: parent.appendingPathComponent("other")).appendingPathComponent("Sources/App/Alpha.swift").path
        var state = TranscriptScanState()
        state.windowLog = ScanWindowLog()
        for line in [
            TranscriptFixture.toolUse("mcp__sift__where", id: "w1", input: ["symbol": "Alpha"], cwd: here.path),
            TranscriptFixture.toolResult(id: "w1", isError: false, text: "tree: here  head: abc1234  dirty: 0  parse_errors: 0\nSources/App/Alpha.swift:3 struct Alpha"),
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sed -n 1,5p \(other)"], cwd: here.path),
        ] {
            _ = TranscriptScan.events(line: line, state: &state, belowFloor: { _ in false })
        }
        let window = try #require(state.windowLog?.windows.last)

        #expect(window.classification == "cold")
        #expect(window.locator == nil)
    }

    /// A whole-file answer the hook gave in place after a `cd` into a checkout since removed decides the floor of its file there, placed from where the line moved rather than the directory it was run from.
    @Test
    func anInPlaceAnswerAfterACdDecidesTheFloorOfItsFileThere() throws {
        let here = try MCPTestRepo.make()
        let gone = here.appendingPathComponent(".claude/worktrees/agent-gone").path
        let answer = TranscriptFixture.fileDigest("Sources/App/Alpha.swift", servedSource: true, tree: "repo (worktree agent-gone)")
        let reason = InPlaceAnswer.reason(calls: ["digest Sources/App/Alpha.swift"], answer: answer, source: nil, standsIn: "", wholeCommand: false).text
        let lookups = TranscriptFixture.lookups(
            [
                TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd \(gone) && cat Sources/App/Alpha.swift"], cwd: here.path),
                TranscriptFixture.toolResult(id: "b1", isError: true, text: "PreToolUse:Bash hook error: " + reason),
                TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": gone + "/Sources/App/Alpha.swift"], cwd: here.path),
            ],
            belowFloor: { _ in false }
        )

        #expect(lookups.last == .belowFloor(file: gone + "/Sources/App/Alpha.swift"))
    }
}
