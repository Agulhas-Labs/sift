//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// What the hook does with an alternation, decided at three layers that have to agree about one command.
///
/// The pattern's reading says which branches are names at all (``SweepPattern``); the search rules say whether the offer is worth its round trips (``TextSearch/reason(for:)``); the declaredness gate says whether any index can answer for the names the offer ended up standing on (`PreToolUseCommand.lookup`). Each can withhold on its own, and each is blind to what the one before it already dropped — so what a caller actually meets is only visible end to end, which is what every test here drives.
///
/// A suite of its own because the two it would otherwise join, `AdviceAgreementTests` and `NeverRefusedShapesTests`, are both at the size a type's body may span, and because the subject is one: the branches a caller wrote against the branches an offer covers.
@Suite(.temporaryDirectories)
struct AlternationWithholdingTests {
    private static func lookup(_ command: String, noting log: SuppressionLog) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: nil,
            noting: log
        ) { _, _ in true }
    }

    /// A branch of prose beside a name leaves the lookup standing on the names, as the offer the answer given in its place names (`InPlaceNamesPartialTests`), and the scan counts the sweep as the lookup it is.
    ///
    /// The ask was either branch, so an offer standing on the names alone answers for part of what was asked. That is given only as an answer saying so — it names the prose it leaves to the identical re-run — and the reading keeps the prose beside the names for it to name, so nothing is narrowed in silence.
    @Test(arguments: [
        (#"grep -rn "UsageWindow\|stale index" Sources --include=*.swift"#, "where UsageWindow"),
        (#"grep -rn "UsageWindow\|UsageLog\|stale index" Sources --include=*.swift"#, "where UsageWindow\nwhere UsageLog"),
        (#"grep -rn "signedDelta\|stale gate" Sources --include=*.swift"#, "where signedDelta"),
        (#"grep -rn "\brounding\b\|stale gate" Sources --include=*.swift"#, "where rounding"),
    ])
    func anAlternationOfANameAndProseStandsOnTheName(command: String, call: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log)?.suggestion.call == call, "\(command)")
        #expect(recording.rules.isEmpty, "\(command)")

        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", input: ["command": command])])
        #expect(tally.textSearches == 0, "\(command)")
        #expect(tally.total == 1, "\(command)")
    }

    /// The advisor builds one file's digest for an alternation on that file, standing on every name in it — and no caller ever meets it, because the price rule withholds the shape before the declaredness gate that digest was shaped for is reached.
    ///
    /// The offer and the withholding are pinned together because either alone passes while the claim is false: a test of the advisor would still pass if the hook started offering this, and a test of the hook would still pass if the advisor stopped building it. Which the rule is right about is the price: the arithmetic it is named for — one `where` per name against one grep — was the offer when it was measured, and one named file now draws this single digest instead, which gives the file's shape back and locates neither name's sites. A weaker answer than the one the measurement refused, so the verdict stands and the digest stays unreached.
    @Test
    func theDigestForAnAlternationOnOneFileIsBuiltAndNeverOffered() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let command = #"grep -n "waitForExit\|temporaryLog" Sources/App/Depot.swift"#
        let offer = try #require(ShellAdvice.suggestion(for: command))

        #expect(offer.call == "digest Depot")
        #expect(offer.symbols == ["waitForExit", "temporaryLog"])
        #expect(Self.lookup(command, noting: recording.log) == nil)
        #expect(recording.rules == ["severalNames"])
    }

    /// Declaration syntax is not prose and takes nothing from the name beside it: the branch carries no name of its own, but it is a question the index answers, so the nudge stands.
    @Test(arguments: [
        (#"grep -rn "final class\|signedDelta" Sources --include=*.swift"#, "where signedDelta"),
        (#"grep -rn "@Test func\|makePreview" Sources --include=*.swift"#, "where makePreview"),
    ])
    func declarationSyntaxBesideANameKeepsTheNudge(command: String, call: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log)?.suggestion.call == call, "\(command)")
        #expect(recording.rules.isEmpty, "\(command)")
    }
}
