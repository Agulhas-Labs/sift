//
// Copyright © Agulhas Labs
//

/// What the always-loaded rule (`Sift.md`) no longer carries, placed in the help topic that now holds it.
///
/// A type of its own rather than more of ``HelpTopics``, whose file is at the line limit with every topic in it.
struct RuleTopicNotes {
    /// The exit codes, the `inventory:` line and the proof recipe, placed at the end of the `run-output` topic.
    static var run: String {
        """
        **`sift run --` exit codes.** The wrapped command's exit code is passed through, except 4 (a \
        `--filter` run that executed no test) and 5 (such a run that did not build), which are sift's.

        **Discovered against run.** `inventory: N declared, M reported`, not `swift test list | grep -c`, is \
        discovered vs run; only an unfiltered, serial `swift test`, root or nested package, or an \
        `xcodebuild` test of its `<Name>-Package` scheme, prints it (`inventory: not checked — …` is another \
        outcome, as for any other unnarrowed `xcodebuild` test).

        **Proving a test fails without your change.** `sift run --without Sources -- swift test --filter …` \
        in one call (a committed fix: add `--since <base>`), never a hand-rolled revert; \
        `--without-line Sources/X.swift:42` when the fix cannot build set aside.
        """
    }

    /// The reading-code habits, placed in the `queries` topic after `digest`.
    static var readingCode: String {
        """
        **Reading code.** Reach for `digest` before the first look at a Swift file, and the shell is \
        where they are most often skipped (`grep -n`, `sed -n '/pattern/p'`, `grep -rn Symbol Sources/`). \
        Digest to locate, then a *ranged* Read of only the members that matter. Already making a Bash \
        call for `git` or `gh`? `sift digest …` and `sift where …` go in the same line. Never judge the \
        size first: below about 60 lines `digest` returns the source, and for a larger file the \
        digest is usually the smaller answer. Reaching for Read because a file "looks small" is the one \
        case that is always wasted.
        """
    }

    /// What to do when the index tools are missing or vanish, placed in the `answers` topic beside the account of `sift status`.
    static var toolsMissing: String {
        """
        **If no `sift` tools are present,** use the Bash CLI if `sift` is on PATH, else ignore the rule and \
        use Read/Grep — a missing server is not a problem to report or fix. **If the index tools vanish \
        mid-session, the CLI keeps working — use it, don't fall back to Grep**, since the CLI does not \
        depend on the server at all: `sift digest <Type>`, `sift where <Symbol>`, `sift search '<query>'`, \
        `sift strings "<text>"`. **Stop a sift server by its pid (`sift servers`), never by a pattern** — \
        `pkill -f "sift mcp"` ends every other session's server too.
        """
    }
}
