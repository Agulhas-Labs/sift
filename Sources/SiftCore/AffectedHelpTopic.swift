//
// Copyright © Agulhas Labs
//

/// The text `sift help affected-limits` prints: the standing limits an `affected` answer used to repeat in full, and how it names a target.
///
/// Built from ``AffectedBlindSpots`` so the list the answer points at and the one it counts (`N ways`) are one list. A type of its own, like ``WorktreeIndexTopic``, because ``HelpTopics`` has outgrown its line limit.
struct AffectedHelpTopic {
    /// The topic as ``HelpTopics`` lists it, kept here so its entry costs the topic list one expression and not a screen of lines.
    static var topic: HelpTopics.Topic {
        HelpTopics.Topic(
            name: "affected-limits",
            summary: "What `sift affected` cannot see, the standing limits its answer points at instead of repeating, and how a target past the list cap is named.",
            body: body
        )
    }

    /// The topic's body.
    static var body: String {
        let limits = AffectedBlindSpots.permanent.map { "- \($0)" }.joined(separator: "\n")
        return """
        **What `affected` cannot see, always.** Each answer opens with two lines: how it was answered and \
        that it is a lower bound, and the limits specific to it (the hop bound, files outside the indexed \
        roots, a cap that fired). The standing list lives here instead:

        \(limits)
        - the reference walk is bounded (two hops by default): a test reaching the change through a longer chain of helpers is not listed, and a bounded walk is bounded

        **When the answer prints runner arguments.** \(AffectedBlindSpots.moduleNameCaveat)

        **When a test sits in a nested XCTest case.** \(AffectedBlindSpots.nestedXCTestCaseCaveat)

        **\(AffectedBlindSpots.conclusion)**

        **A target named by commands, once.** A target past the list cap is never listed test by test. \
        Where every test in it is affected the answer says `all N tests` with both runners' commands; \
        where half its tests or more are reached it says it could not narrow below the target and gives \
        `--filter '<Target>'` and `-only-testing:<Target>`; below half it gives the commands that run \
        exactly the affected suites. A target named this way is not repeated in the `xcodebuild` and \
        `swift test` sections, which carry only the targets that are listed.

        **Right after an edit** the store is older than your change and refuses the changed files; the \
        answer then walks from the declarations the diff touched to their call sites as syntactic `where` \
        finds them, and says so. Rebuild (`sift run -- swift build`) for the resolved walk.
        """
    }
}
