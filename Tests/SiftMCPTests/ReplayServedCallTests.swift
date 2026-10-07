//
// Copyright © Agulhas Labs
//

@testable import SiftMCP
import Testing

/// `audit --replay --against`: a call both hooks answer in place under one rule, but through another index call, is a difference, named by both calls.
struct ReplayServedCallTests {
    /// Two verdicts alike in token and rule but answered by another index call are a difference, listed under the rule with both calls shaped so no path is printed.
    @Test func aChangedServedCallIsListedWithBothCalls() {
        var context = ContextReplay()
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "sed -n 10,20p Sources/App/Depot.swift"]]
        context.compare(
            ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: "digest Sources/App/Depot.swift"),
            with: ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: "digest Sources/App/Depot.swift:10-20"),
            payload: payload
        )

        let section = ReplayComparison.lines([context])

        #expect(section.contains("  differ          1  of the 1 calls in the window"), "\(section)")
        #expect(section.contains("         1  ShellAdvice [call digest <file> → digest <file>:<range>]"), "\(section)")
        #expect(!section.contains { $0.contains("Depot") }, "\(section)")
    }

    /// A served call is shaped word by word: `sift` and the index tool as written, a symbol or file as its kind, a window as `:<range>`, and no call as `none`.
    @Test func aServedCallIsShapedToNameNothingInTheTree() {
        #expect(ContextReplay.shaped("sift where Depot") == "sift where <text>")
        #expect(ContextReplay.shaped("digest Sources/App/Depot.swift:12") == "digest <file>:<range>")
        #expect(ContextReplay.shaped(nil) == "none")
    }

    /// A served call whose target moved shapes alike on both sides, so an unredacted report shows the two calls as written beside the label, and a redacted one still names nothing in the tree.
    @Test func aMovedTargetIsShownAsWrittenOnlyWhenUnredacted() {
        var context = ContextReplay()
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "cat Sources/App/Depot.swift"]]
        context.compare(
            ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: "digest Sources/App/Depot.swift"),
            with: ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: "digest Sources/Store/Depot.swift"),
            payload: payload
        )
        let label = "         1  ShellAdvice [call digest <file> → digest <file>]"

        let redacted = ReplayComparison.lines([context])
        let unredacted = ReplayComparison.lines([context], unredacted: true)

        #expect(redacted.contains(label), "\(redacted)")
        #expect(!redacted.contains { $0.contains("Depot") }, "\(redacted)")
        #expect(unredacted.contains(label + " — e.g. `digest Sources/App/Depot.swift → digest Sources/Store/Depot.swift`"), "\(unredacted)")
    }
}
