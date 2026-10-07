//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the allow rules `install-hook` offers against what the build rewrite emits: every wrapped form covered in a session that asks, and nothing else.
struct RunAllowRulesCoverageTests {
    /// The permission the hook reads where the offered rules are the only ones.
    private static let permission = WrappedRunPermission(allowed: WrappedRunPermission.patterns(in: RunAllowRules.rules), vetoed: [])

    /// Every build the hook rewrites, in the forms an agent writes them, adds no prompt in the default mode once the rules are there.
    @Test(arguments: [
        "swift build",
        "swift build -c release",
        "swift test",
        "swift test --filter 'Foo|Bar'",
        "swift build && swift test",
        "cd Kit && swift test",
        "(cd Kit && swift test)",
        "{ cd Kit && swift build; }",
        "xcodebuild test -scheme Gizmo -quiet",
        "xcodebuild -scheme Gizmo build",
        "swiftlint lint --strict",
        "swiftlint",
    ])
    func everyRewrittenBuildIsCovered(shell: String) {
        let legs = RunAdvice.wrappedLegs(of: shell)

        #expect(!legs.isEmpty)
        #expect(Self.permission.addsNoPrompt(legs: legs, mode: "default"))
    }

    /// A group's own closing delimiter is not part of the leg, but a parenthesis the command owns is.
    @Test(arguments: [
        ("(cd Kit && swift test)", "sift run -- swift test"),
        ("{ cd Kit && swift build; }", "sift run -- swift build"),
        ("((cd Kit && swift test))", "sift run -- swift test"),
        ("(cd Kit && swift test --filter ')')", "sift run -- swift test --filter ')'"),
        ("(cd Kit && swift test --filter \"a)\")", "sift run -- swift test --filter \"a)\""),
        ("(cd Kit && swift test --filter $(echo x))", "sift run -- swift test --filter $(echo x)"),
    ])
    func aGroupsOwnDelimitersAreNotTheLegs(shell: String, leg: String) {
        #expect(RunAdvice.wrappedLegs(of: shell) == [leg])
    }

    /// The rules allow the wrapper in front of the four builds and in front of nothing else.
    @Test(arguments: ["sift run -- rm -rf build", "sift run -- swift run", "sift run -- swift package reset", "sift run", "sift build"])
    func nothingElseIsCovered(leg: String) {
        #expect(!Self.permission.addsNoPrompt(legs: [leg], mode: "default"))
    }
}
