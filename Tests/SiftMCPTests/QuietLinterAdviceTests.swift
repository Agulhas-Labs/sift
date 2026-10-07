//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers the quiet-linter rule: a linter run carrying `--quiet` has no log for `sift run --` to spare, so it draws no wrapping.
@Suite(.temporaryDirectories)
struct QuietLinterAdviceTests {
    private static func shell(_ command: String) -> [String: Any] {
        ["tool_name": "Bash", "tool_input": ["command": command]]
    }

    /// A quiet lint is offered nothing, wherever the flag sits and whatever else the line runs that is no build.
    @Test
    func aQuietLintDrawsNoWrapping() {
        #expect(RunAdvice.suggestion(for: "swiftlint lint --quiet") == nil)
        #expect(RunAdvice.suggestion(for: "swiftlint lint --strict --quiet A.swift") == nil)
        #expect(RunAdvice.suggestion(for: "swiftlint --quiet") == nil)
        #expect(RunAdvice.suggestion(for: "swiftlint lint --strict --quiet A.swift; echo lint=$?; git status") == nil)
    }

    /// The rule silences only its own statement: another toolchain statement on the line keeps its wrapping.
    @Test
    func anotherBuildOnTheLineKeepsItsWrapping() throws {
        let call = try #require(RunAdvice.suggestion(for: "swiftlint lint --quiet; swift test")).call
        #expect(call == "swiftlint lint --quiet; sift run -- swift test")
        let chained = try #require(RunAdvice.suggestion(for: "swift build && swiftlint lint --strict --quiet")).call
        #expect(chained == "sift run -- swift build && swiftlint lint --strict --quiet")
    }

    /// Only a linter run and only the exact token: a loud lint, a quiet build and a near-miss flag all keep the wrapping as before.
    @Test
    func theRuleIsNarrow() throws {
        #expect(try #require(RunAdvice.suggestion(for: "swiftlint lint --strict")).call == "sift run -- swiftlint lint --strict")
        #expect(try #require(RunAdvice.suggestion(for: "swiftlint lint --quiet-mode")).call == "sift run -- swiftlint lint --quiet-mode")
        #expect(try #require(RunAdvice.suggestion(for: "swiftlint lint -q")).call == "sift run -- swiftlint lint -q")
        #expect(try #require(RunAdvice.suggestion(for: "xcodebuild -quiet -scheme Gizmo test")).call
            == "sift run -- xcodebuild -quiet -scheme Gizmo test")
        #expect(try #require(RunAdvice.suggestion(for: "swift build --quiet")).call == "sift run -- swift build --quiet")
    }

    /// The rule counts as the reason only where it alone left the line without a wrapping.
    ///
    /// A line another refusal silences would have drawn nothing anyway, and a line where another statement is wrapped withheld nothing.
    @Test
    func theRuleIsTheReasonOnlyWhereNothingElseDecided() {
        #expect(RunAdvice.silencedAsAQuietLinter("swiftlint lint --quiet"))
        #expect(RunAdvice.silencedAsAQuietLinter("swiftlint lint --strict --quiet A.swift; echo lint=$?; git status"))
        #expect(!RunAdvice.silencedAsAQuietLinter("swiftlint lint --quiet; swift test"))
        #expect(!RunAdvice.silencedAsAQuietLinter("swiftlint lint --quiet | tail -5"))
        #expect(!RunAdvice.silencedAsAQuietLinter("swiftlint lint --quiet > lint.log"))
        #expect(!RunAdvice.silencedAsAQuietLinter("swiftlint lint --quiet; swift test 2>&1 | tail -5"))
        #expect(!RunAdvice.silencedAsAQuietLinter("sift run -- swiftlint lint --quiet"))
        #expect(!RunAdvice.silencedAsAQuietLinter("swiftlint lint --strict"))
        #expect(!RunAdvice.silencedAsAQuietLinter("git status"))
    }

    /// The withholding is recorded under a rule of its own, since no share counts a toolchain run and the fire rate is the only evidence it is not over-firing.
    @Test
    func aWithheldQuietLintIsRecorded() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let lookup: (String) -> PreToolUseCommand.Lookup? = { command in
            PreToolUseCommand.lookup(command: nil, payload: Self.shell(command), in: nil, noting: recording.log) { _, _ in true }
        }

        #expect(lookup("swiftlint lint --strict --quiet A.swift; echo lint=$?") == nil)
        #expect(recording.rules == ["quietLinter"])

        // A line where another statement drew a wrapping withheld nothing, and one another rule silenced is that rule's.
        _ = lookup("swiftlint lint --quiet; swift test")
        #expect(lookup("swiftlint lint --quiet > lint.log") == nil)
        #expect(lookup("swiftlint lint --quiet | tail -5") == nil)
        #expect(recording.rules == ["quietLinter", "gateLeg"])
    }
}
