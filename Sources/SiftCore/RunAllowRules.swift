//
// Copyright © Agulhas Labs
//

import Foundation

/// The `Bash` allow rules `install-hook` offers to add, so a build the `PreToolUse` hook rewrites to `sift run -- …` runs without a permission prompt.
///
/// Claude Code matches its permission rules against the rewritten command, so without one of these a session that asks about commands gets the build refused with its wrapping named instead, and pays a turn for it. There is one rule per command the rewrite puts the wrapper in front of — `swift build`, `swift test`, `xcodebuild` and `swiftlint` — rather than `Bash(sift run:*)`, which would allow `sift run -- ` in front of anything at all. They are written in the legacy `prefix:*` form, which every Claude Code version reads.
///
/// A build spelled another way — a path to the executable, or a flag before `swift`'s subcommand — is not covered, and is refused with its wrapping as before.
///
/// Nothing records what was added: an install that adds appends the four rules as one contiguous block in the order of `rules`, even where some are already there, since a duplicate in `allow` is harmless, and removal takes out exactly one such block — the last — and leaves every other copy, so a rule the user wrote stays. An install that finds all four already present adds nothing. What this cannot tell apart is a user who typed that exact contiguous block in order: removal takes the last such block, since telling it apart would need a record of what the install wrote.
public struct RunAllowRules {
    /// The rules, in the order an install appends them.
    public static let rules = [
        "Bash(sift run -- swift build:*)",
        "Bash(sift run -- swift test:*)",
        "Bash(sift run -- xcodebuild:*)",
        "Bash(sift run -- swiftlint:*)",
    ]

    private static let block = AllowRuleBlock(rules: rules)

    /// The rules `data`'s `permissions.allow` list does not already hold, in the order an install would append them.
    public static func missing(from data: Data?) throws -> [String] {
        try block.missing(from: data)
    }

    /// `data` with the whole set appended to `permissions.allow` as one block, creating either where it is absent, or `nil` where every rule is already there.
    public static func adding(to data: Data?) throws -> Data? {
        try block.adding(to: data)
    }

    /// `data` with the last contiguous, in-order block of the set taken out of `permissions.allow`, pruning a list or object that leaves empty, or `nil` where there is no such block.
    public static func removing(from data: Data?) throws -> Data? {
        try block.removing(from: data)
    }
}
