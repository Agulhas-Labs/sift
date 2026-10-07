//
// Copyright © Agulhas Labs
//

@testable import SiftCLI
import SiftMCP
import Testing

/// Covers the shape of the refusal text `PreToolUseCommand.reason(for:)` builds — the one place it still runs, now that a lookup answers in place or is let through: the `sift run --` wrapping's one-shot deny.
struct DenialTextTests {
    /// Every line of the offered call is indented, not only the first.
    ///
    /// A suggestion is a rebuild of the whole command the caller wrote, so a command spanning several lines produces a call that does too. Interpolated into one indented slot, the continuation lands flush against the margin and stops reading as part of the command being offered.
    @Test
    func aMultiLineCallIsIndentedThroughout() throws {
        let suggestion = try #require(RunAdvice.suggestion(for: "swift build\nswift test"))
        let lines = suggestion.call.split(separator: "\n")
        try #require(lines.count > 1)

        let reason = PreToolUseCommand.reason(for: suggestion)

        for line in lines {
            #expect(reason.contains("\n    \(line)"))
            #expect(!reason.contains("\n\(line)"))
        }
    }

    /// The single-line case the template was written for is unchanged by the same code path.
    @Test
    func aSingleLineCallKeepsItsOneIndentedLine() throws {
        let suggestion = try #require(RunAdvice.suggestion(for: "swift test"))

        let reason = PreToolUseCommand.reason(for: suggestion)

        #expect(reason.contains("\n    sift run -- swift test\n"))
        #expect(reason.contains("\n    → "))
    }

    /// A line holding more than its build is told how far the wrapper reaches.
    ///
    /// The offered line opens with the wrapper where the build is its first statement, and nothing else tells it apart from a wrapping of the whole line.
    @Test(arguments: [
        "swift test; git add -A && git commit -q -m 'msg'",
        "cd Kit && swift test",
        "swift build; echo built=$?; swift test",
    ])
    func aLineHoldingMoreThanItsBuildSaysHowFarTheWrapperReaches(command: String) throws {
        let suggestion = try #require(RunAdvice.suggestion(for: command))

        #expect(suggestion.offer.contains("wraps only the statement it stands in front of"))
        #expect(PreToolUseCommand.reason(for: suggestion).contains("the rest of the line runs as written"))
    }

    /// A line that is nothing but its builds keeps the short offer, there being no rest of the line to speak of.
    @Test(arguments: ["swift test", "swift build && swift test", "swift build\nswift test"])
    func aLineThatIsAllBuildsKeepsTheShortOffer(command: String) throws {
        let suggestion = try #require(RunAdvice.suggestion(for: command))

        #expect(suggestion.offer == "sift serves this command's failures instead of its whole log:")
    }
}
