//
// Copyright © Agulhas Labs
//

@testable import SiftMCP
import Testing

/// `audit --replay --against --unredacted`: the two served calls beside a changed-call row are each cut to the width on their own, so the right-hand call survives a long left-hand one.
struct ReplayServedCallClipTests {
    /// A left-hand call longer than the width, beside a right-hand one whose difference sits at its end, still prints the right-hand call whole, with the left-hand one cut to the width.
    @Test func aLongLeftHandCallLeavesTheRightHandOneWhole() {
        let deep = "Sources/" + Array(repeating: "Warehouse", count: 14).joined(separator: "/")
        let (theirs, ours) = ("digest \(deep)/Depot.swift", "digest Sources/Warehouse/Crate.swift")
        var context = ContextReplay()
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "cat \(deep)/Depot.swift"]]
        context.compare(
            ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: theirs),
            with: ReplayVerdict(token: "in-place", rule: "ShellAdvice", call: ours),
            payload: payload
        )
        let clippedTheirs = String(theirs.prefix(ReplayColdShapes.width - 1)) + "…"

        let section = ReplayComparison.lines([context], unredacted: true)

        #expect(theirs.count > ReplayColdShapes.width)
        #expect(section.contains { $0.hasSuffix(" — e.g. `\(clippedTheirs) → \(ours)`") }, "\(section)")
    }
}
