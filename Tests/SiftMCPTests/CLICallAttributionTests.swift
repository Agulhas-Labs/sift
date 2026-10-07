//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A subagent's lookup through Bash is attributed to the subagent, and the slip that names it can be claimed by that lookup alone — never by an MCP call of the same shape in flight under the same session, nor the other way round.
@Suite(.temporaryDirectories)
struct CLICallAttributionTests {
    private static func store() throws -> (CallAttribution, URL) {
        let directory = try TemporaryDirectory.make("callers")
            .appendingPathComponent("callers")
        return (CallAttribution(directory: directory), directory)
    }

    private static func bash(_ command: String, agent: String?) -> [String: Any] {
        var payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
        if let agent {
            payload["agent_id"] = agent
        }
        return payload
    }

    /// The hook names each lookup by the argv its subcommand will see: the words after the binary, unquoted, with the redirection the shell consumes cut off — and a `sift` that is no lookup gets no slip.
    @Test
    func aShellLookupIsNamedByTheArgvItsSubcommandWillSee() {
        let command = #"SIFT_USAGE_LOG=x sift search "kind:struct attr:Test" 2>&1 | head -5; "#
            + #"cd /work && sift digest Sources/App/Depot.swift --root '/work/app' > out.txt; sift run -- swift build"#

        #expect(IndexCallTarget.cliLookups(inCommand: command) == [
            ["search", "kind:struct attr:Test"],
            ["digest", "Sources/App/Depot.swift", "--root", "/work/app"],
        ])
    }

    /// A quoted word that only looks like a redirection is kept whole: the cut is read off the argv as it was written, quotes and all, not off the unquoted value the redirection regex would otherwise match.
    @Test
    func aQuotedWordStartingWithARedirectionCharacterIsKeptWhole() {
        let command = #"sift strings "<Settings>""#

        #expect(IndexCallTarget.cliLookups(inCommand: command) == [
            ["strings", "<Settings>"],
        ])
    }

    /// A `sift` statement joined to a preceding non-`sift` statement by `&&` still files — the commonest shape a subagent writes (`cd /work && sift where A`), and the reading cannot know whether `cd` succeeded.
    @Test
    func aShellLookupAfterANonSiftStatementStillFiles() {
        #expect(IndexCallTarget.cliLookups(inCommand: "cd /work && sift where A") == [
            ["where", "A"],
        ])
    }

    /// The whole mechanism for the shell: the hook sees the agent on the Bash call, and the lookup that call starts claims it by its argv.
    @Test
    func aSubagentsShellLookupIsAttributedToTheSubagent() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.bash("sift where Depot --root /work | head -40", agent: "adae5f77"), into: callers)

        #expect(callers.take(session: "s1", arguments: ["where", "Depot", "--root", "/work"]) == "adae5f77")
        #expect(callers.take(session: "s1", arguments: ["where", "Depot", "--root", "/work"]) == nil)
    }

    /// A slip filed under its face is claimed by that face alone, where one filed under its tool and target could be taken by the wrong one.
    @Test
    func neitherFaceClaimsTheOthersSlip() throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server: [String: Any] = ["tool_name": "mcp__sift__where", "tool_input": ["symbol": "Depot"], "agent_id": "b0c1d2e3"]

        PreToolUseCommand.noteCaller(session: "s1", payload: Self.bash("sift where Depot", agent: "adae5f77"), into: callers)
        #expect(callers.take(session: "s1", tool: "where", target: "Depot") == nil)
        PreToolUseCommand.noteCaller(session: "s1", payload: server, into: callers)
        #expect(callers.take(session: "s1", arguments: ["where", "Depot"]) == "adae5f77")
        #expect(callers.take(session: "s1", arguments: ["where", "Depot"]) == nil)
        #expect(callers.take(session: "s1", tool: "where", target: "Depot") == "b0c1d2e3")
    }

    /// A lookup that fails is still the subagent's, and its line says so.
    @Test
    func aFailedShellLookupStillCarriesItsCaller() async throws {
        let (callers, directory) = try Self.store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try TemporaryDirectory.make("usage").appendingPathComponent("usage.jsonl")
        PreToolUseCommand.noteCaller(session: "s1", payload: Self.bash("sift where Depot", agent: "adae5f77"), into: callers)

        await #expect(throws: CocoaError.self) {
            try await LoggedLookup.emit(
                tool: "where",
                target: "Depot",
                in: URL(fileURLWithPath: "/work"),
                usage: UsageLog(fileURL: log),
                session: "s1",
                arguments: ["where", "Depot"],
                callers: callers
            ) { throw CocoaError(.fileNoSuchFile) }
        }

        let line = try String(contentsOf: log, encoding: .utf8)

        #expect(UsageScan.Entry(line: Data(line.utf8))?.agent == "adae5f77")
        #expect(UsageScan.Entry(line: Data(line.utf8))?.succeeded == false)
    }
}
