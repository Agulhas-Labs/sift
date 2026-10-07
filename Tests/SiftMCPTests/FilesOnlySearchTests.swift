//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A search printing only the names of the files it matches, or how many lines match, runs as it would have without the hook, and is counted as no miss.
///
/// The list is already the smallest answer to "which files", and it holds the files whose only mention is a comment or a string, which no `where` lists. So it is let through under a rule of its own on either surface, and the scan scores it out of the share on the same verdict.
@Suite(.temporaryDirectories) struct FilesOnlySearchTests {
    /// What the hook makes of `payload`: the lookup it would answer, and the rules it logged instead.
    private static func judged(_ payload: [String: Any]) throws -> (lookup: PreToolUseCommand.Lookup?, rules: [String]) {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let lookup = PreToolUseCommand.lookup(command: nil, payload: payload, in: nil, noting: recording.log) { _, _ in true }
        return (lookup, recording.rules)
    }

    /// A `Grep` printing file names, its default mode included, is let through as `filesOnly` and counted as no miss.
    @Test(arguments: [["output_mode": "files_with_matches"], [:]] as [[String: String]])
    func aGrepListingFilesRunsUnanswered(mode: [String: String]) throws {
        let input = mode.merging(["pattern": "InPlaceShape", "glob": "*.swift", "head_limit": "0"]) { $1 }
        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: input) == .filesOnly)

        let judged = try Self.judged(["tool_name": "Grep", "tool_input": input])
        #expect(judged.lookup == nil)
        #expect(judged.rules == ["filesOnly"])

        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Grep", id: "g1", input: input)])
        #expect(tally.cold == 0)
        #expect(tally.withheldOnWorthCauses.filesOnly == 1)
    }

    /// A `Grep` counting its matches is let through too, as the count it always was.
    @Test
    func aGrepCountingRunsUnanswered() throws {
        let input: [String: Any] = ["pattern": "InPlaceShape", "glob": "*.swift", "output_mode": "count"]
        let judged = try Self.judged(["tool_name": "Grep", "tool_input": input])

        #expect(judged.lookup == nil)
        #expect(judged.rules == ["textSearch"])
        #expect(TranscriptFixture.tally([TranscriptFixture.toolUse("Grep", id: "g1", input: input)]).cold == 0)
    }

    /// A `Grep` printing the lines that match a declared name is judged exactly as before: answered with that name's `where`, and a miss.
    @Test
    func aGrepPrintingLinesIsStillALookup() throws {
        let input: [String: Any] = ["pattern": "InPlaceShape", "glob": "*.swift", "output_mode": "content"]
        #expect(SearchToolAdvice.textSearchReason(tool: "Grep", input: input) == nil)

        let judged = try Self.judged(["tool_name": "Grep", "tool_input": input])
        #expect(judged.lookup?.suggestion.call == "where InPlaceShape")
        #expect(judged.rules.isEmpty)
        #expect(TranscriptFixture.tally([TranscriptFixture.toolUse("Grep", id: "g1", input: input)]).cold == 1)
    }

    /// Every shell spelling of a file list, alone and inside a cluster, is let through as `filesOnly` and counted as no miss.
    @Test(arguments: [
        "grep -l InPlaceShape Sources --include=*.swift",
        "grep -rL InPlaceShape Sources --include=*.swift",
        "grep -rlw InPlaceShape Sources --include=*.swift",
        "grep -lnr InPlaceShape Sources --include=*.swift",
        "grep -rln -i 'open question|rounding' Sources --include=*.swift",
        "grep -r --files-with-matches InPlaceShape Sources --include=*.swift",
        "grep -r --files-without-match InPlaceShape Sources --include=*.swift",
        "egrep -rl InPlaceShape Sources --include=*.swift",
        "rg -l InPlaceShape -g '*.swift'",
        "rg -wl InPlaceShape -g '*.swift'",
        "rg --files-with-matches InPlaceShape -g '*.swift'",
        "rg --files-without-match InPlaceShape -g '*.swift'",
        "cd Sources && grep -rlw InPlaceShape . --include=*.swift | head -20",
    ])
    func aShellFileListRunsUnanswered(command: String) throws {
        #expect(ShellAdvice.textSearchReason(command, holdsSource: { _ in true }) == .filesOnly)

        let judged = try Self.judged(["tool_name": "Bash", "tool_input": ["command": command]])
        #expect(judged.lookup == nil)
        #expect(judged.rules == ["filesOnly"])

        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command])])
        #expect(tally.cold == 0)
        #expect(tally.withheldOnWorthCauses.filesOnly == 1)
    }

    /// Every shell spelling of a count is let through as the count it always was, and counted as no miss.
    @Test(arguments: [
        "grep -c InPlaceShape Sources/SiftMCP/InPlaceShape.swift",
        "grep -rcw InPlaceShape Sources --include=*.swift",
        "grep -r --count InPlaceShape Sources --include=*.swift",
        "rg -c InPlaceShape -g '*.swift'",
        "rg --count InPlaceShape -g '*.swift'",
        "rg --count-matches InPlaceShape -g '*.swift'",
    ])
    func aShellCountRunsUnanswered(command: String) throws {
        #expect(ShellAdvice.textSearchReason(command, holdsSource: { _ in true }) == .textSearch)
        #expect(try Self.judged(["tool_name": "Bash", "tool_input": ["command": command]]).lookup == nil)
        #expect(TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command])]).cold == 0)
    }

    /// A letter that lists files to one tool and not another, or that stands where a value belongs, leaves the search judged as before.
    @Test(arguments: [
        "rg -L InPlaceShape -g '*.swift'",
        "grep -rn -e -l Sources --include=*.swift",
        "grep -rn InPlaceShape Sources --include=*.swift",
    ])
    func aLetterThatListsNothingIsStillALookup(command: String) {
        #expect(ShellAdvice.textSearchReason(command, holdsSource: { _ in true }) != .filesOnly)
    }

    /// The rule belongs to the half the index could answer for more than the command costs, with a counter and an audit line of its own.
    @Test
    func theRuleIsCountedOnItsOwnLine() {
        #expect(TextSearch.Reason.filesOnly.withholding == .notWorthTheRoundTrips)
        #expect(TextSearch.Reason.filesOnly.rule == .filesOnly)
        var causes = WithholdOnWorthCauses()
        causes[.filesOnly] += 1
        #expect(causes.filesOnly == 1)
        #expect(causes.total == 1)
    }
}
