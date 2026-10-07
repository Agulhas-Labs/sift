//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// `--without-line` only ever comments a line out, so `sift run --help` says which lines that cannot neutralise and what to use instead.
struct RunWithoutLineLimitHelpTests {
    /// The option's own help, the one line a reader scanning the flags sees, says a block-opening `guard` does not compile commented out.
    @Test
    func theOptionHelpSaysABlockOpeningGuardCannotBeCommentedOut() {
        let help = RunCommand.helpMessage().split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(help.contains("Comment out this one line of a Swift file"), "\(help)")
        #expect(help.contains("The file has to compile with the line commented out: a one-line `guard !… else { return }` that binds no name does, unless it is the last reader of a local above it (route it through a helper whose parameters carry the inputs); a `guard … else {` that opens a block does not."), "\(help)")
    }

    /// The discussion says a guard that is the last reader of a local above it leaves that local unused, and the way round it.
    @Test
    func theDiscussionSaysAGuardThatIsTheLastReaderOfALocalCannotBeCommentedOut() {
        let discussion = RunCommand.configuration.discussion.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(discussion.contains("Nor a guard that is the last reader of a local above it: the local is left unused, which a warnings-as-errors package refuses, so route it through a helper whose parameters carry the inputs."))
    }

    /// The discussion names both lines a guard fix cannot use — the opening line and the exit inside it — and the fallback.
    @Test
    func theDiscussionNamesTheGuardLinesAndTheFallback() {
        let discussion = RunCommand.configuration.discussion.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(discussion.contains("A `guard let` or `let` whose name a later line uses does not compile commented out"))
        #expect(discussion.contains("a `guard … else {` that opens a block does not either, and neither does the `return` or `throw` inside one"))
        #expect(discussion.contains("such a fix needs --without, or a set-aside by hand"))
    }
}
