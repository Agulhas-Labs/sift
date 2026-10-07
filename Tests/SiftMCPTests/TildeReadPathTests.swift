//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A shell read naming its file from the home directory, `cat ~/…`, is judged against what this context holds as its absolute spelling is: the shell expands the `~` before the read runs.
@Suite(.temporaryDirectories)
struct TildeReadPathTests {
    /// A whole read of a held file spelled from `~` is let through, through either record of the digest, where the same read with nothing held is still answered.
    @Test(arguments: [false, true])
    func aTildeReadOfAHeldFileIsLetThrough(throughTheUsageLog: Bool) throws {
        let fixture = try HeldWindowLineTests.fixture()
        if !throughTheUsageLog {
            fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        }
        let command = "cat \(Self.fromHome(fixture.repo))/Sources/App/Shell.swift"

        let held = try HeldWindowLineTests.judged(command, in: fixture, located: throughTheUsageLog)
        let cold = try HeldWindowLineTests.judged(command, in: fixture, session: "s2")

        // Held through the usage log, the read is no lookup at all; through the ledger, it is let through when decided.
        #expect(held.line == (throughTheUsageLog ? "allowed\t\tnoLookup" : "allowed\t\talreadyDigested"))
        let notes = try? String(contentsOf: fixture.stores.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)
        #expect(notes?.contains("alreadyDigested") == true)
        #expect(cold.line.hasPrefix("in-place\t"))
    }

    /// Beside a cold read, the held read spelled from `~` is dropped and the line runs, rather than being denied with the digest the context already holds.
    @Test
    func aTildeReadOfAHeldFileBesideAColdReadLetsTheLineRun() throws {
        let fixture = try HeldWindowLineTests.fixture()

        let judged = try HeldWindowLineTests.judged("cat \(Self.fromHome(fixture.repo))/Sources/App/Shell.swift; cat Sources/App/Other.swift", in: fixture, located: true)

        #expect(judged.line == "allowed\t\totherStatementsRun")
        #expect(judged.json?.contains("permissionDecision") == false)
    }

    /// The read paths the held checks ask about expand a leading `~` to the home directory and leave every other spelling as the plain resolution does.
    @Test
    func readPathsExpandALeadingTilde() throws {
        let home = ("~" as NSString).expandingTildeInPath
        let match = try #require(InPlaceShape.match(forShell: "cat ~/Probe/Alpha.swift; cat Sources/Beta.swift", in: "/repo"))

        #expect(match.wholeReadPaths == ["\(home)/Probe/Alpha.swift", "/repo/Sources/Beta.swift"])
        #expect(match.droppingReads { path, _, _ in path == "\(home)/Probe/Alpha.swift" }?.wholeReadPaths == ["/repo/Sources/Beta.swift"])
        #expect(SwiftTree.resolve(readPath: "~", relativeTo: "/repo") == home)
        #expect(SwiftTree.resolve(readPath: "~other/Alpha.swift", relativeTo: "/repo") == "/repo/~other/Alpha.swift")
    }

    /// A quoted `~` is no home directory: the shell hands `cat` a path under the working directory, so a held file's absolute spelling is not that read, and no in-place answer is given for it.
    @Test(arguments: ["'~/Probe/Alpha.swift'", "\"~/Probe/Alpha.swift\""])
    func aQuotedTildeReadIsNotTheHomeDirectorys(operand: String) {
        let match = ShellQuery("cat \(operand)")

        #expect(match.readPaths == ["./~/Probe/Alpha.swift"])
        #expect(InPlaceShape.match(forShell: "cat \(operand)", in: "/repo") == nil)
    }

    /// The `Read` tool takes an absolute `file_path`, so a `~` should never reach the hook there; this pins what the hook does if one does, which is to read it as the home directory as `cat` does, so a held file spelled from `~` is let through and a cold one is not.
    @Test
    func aReadToolPathSpelledFromTildeIsJudgedAsItsAbsoluteSpelling() throws {
        let fixture = try HeldWindowLineTests.fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": "\(Self.fromHome(fixture.repo))/Sources/App/Shell.swift"]]
        let lookup = try #require(PreToolUseCommand.lookup(command: nil, payload: payload, in: fixture.repo.path, noting: fixture.suppressions, couldAnswer: { _, _ in true }))

        #expect(lookup.readPaths(from: fixture.repo.path) == [SwiftTree.resolve(fixture.file, relativeTo: nil) ?? fixture.file])
        #expect(fixture.verdict(lookup).line == "allowed\t\talreadyDigested")
        #expect(fixture.verdict(lookup, session: "s2").line != "allowed\t\talreadyDigested")
    }

    /// `directory` spelled from `~`: up from the home directory to the root, then down to it.
    private static func fromHome(_ directory: URL) -> String {
        let depth = ("~" as NSString).expandingTildeInPath.split(separator: "/").count
        return "~/" + String(repeating: "../", count: depth) + directory.path.dropFirst()
    }
}
