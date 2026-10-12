//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The audit's scan scores a grep of named Swift files the way the hook reads the same line: let run as a named-file search where the hook's own parser and guard let it run, and a miss where the hook reads it as anything else.
struct ScanNamedFileAgreementTests {
    private static func scored(_ command: String) -> Scored {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command, "description": "find it"]),
            TranscriptFixture.toolResult(id: "b1", isError: false),
        ])
        return Scored(cold: tally.cold, namedFiles: tally.withheldOnWorthCauses.namedFiles)
    }

    /// A stderr redirect the hook drops before reading the operands leaves a search of the files it names, which the hook lets run and the scan does not count as a miss.
    @Test(arguments: [
        "grep -n SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift 2>/dev/null",
        "grep -n SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift 2>&1",
    ])
    func aStderrRedirectLeavesANamedFileSearch(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command) == Scored(cold: 0, namedFiles: 1))
    }

    /// A bare number among the operands is a path to the hook, which is no Swift file, so the search is no named-file search and the scan counts it as the miss the hook let through.
    @Test func aBareNumberOperandIsNoNamedFileSearch() {
        let command = "grep -n SummaryState Sources/App/SummaryState.swift 12 Sources/App/Reader.swift"

        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command) == Scored(cold: 1, namedFiles: 0))
    }

    /// A number is the pattern when it comes first, as the hook reads it, so the line is a search of both files after it and no miss: a pattern naming nothing, scored as such before the named-file rule is asked.
    @Test func aNumberPatternIsNoMiss() {
        let command = "grep -n 12 Sources/App/SummaryState.swift Sources/App/Reader.swift"

        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command).cold == 0)
    }

    /// A quoted `~` is refused by the hook's parser, so the line is no named-file search for the scan either.
    @Test func aQuotedTildeOperandIsNoNamedFileSearch() {
        let command = "grep -n SummaryState '~/SummaryState.swift' Sources/App/Reader.swift"

        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command) == Scored(cold: 1, namedFiles: 0))
    }

    /// The hook's guard does not read the pattern, so a pattern that is no name, over named files, runs as a named-file search in both.
    @Test func theGuardDoesNotReadThePattern() {
        let command = "grep -n 'SummaryState()' Sources/App/SummaryState.swift Sources/App/Reader.swift"

        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command) == Scored(cold: 0, namedFiles: 1))
    }

    /// A verb other than `grep`, or a flag the hook's parser refuses, is no named-file search to the hook, so the scan does not excuse it as one.
    @Test(arguments: [
        "grep -nv SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift",
        "grep -n -e SummaryState -e Reader Sources/App/SummaryState.swift Sources/App/Reader.swift",
        "rg -n SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift",
        "egrep -n SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift",
        "grep -n -m 3 SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift",
    ])
    func whatTheHookDoesNotReadIsNoNamedFileSearch(command: String) {
        #expect(InPlaceShape.match(forShell: command, in: nil) == nil)
        #expect(Self.scored(command).namedFiles == 0)
    }
}

extension ScanNamedFileAgreementTests {
    /// How the scan scored one line run alone: whether it was a miss, and whether it was excused as a named-file search.
    private struct Scored: Equatable {
        var cold: Int
        var namedFiles: Int
    }
}
