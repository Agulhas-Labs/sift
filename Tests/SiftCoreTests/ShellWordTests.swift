//
// Copyright © Agulhas Labs
//

import SiftCore
import Testing

/// Covers `ShellWord.quoted`: judged and rewritten by unicode scalar, so a quote that shares a `Character` with a combining or prepended mark is still escaped.
struct ShellWordTests {
    @Test
    func aWordOfSafeCharactersIsUnchanged() {
        #expect(ShellWord.quoted("/opt/homebrew/bin/sift-1.2_x+y:z") == "/opt/homebrew/bin/sift-1.2_x+y:z")
    }

    @Test
    func aSpaceIsQuoted() {
        #expect(ShellWord.quoted("My Tools/sift") == "'My Tools/sift'")
    }

    @Test
    func aPlainQuoteIsClosedEscapedAndReopened() {
        #expect(ShellWord.quoted("a'b") == #"'a'\''b'"#)
    }

    @Test
    func aQuoteBeforeACombiningMarkIsEscaped() {
        #expect(ShellWord.quoted("q'\u{301}x") == "'q'\\''\u{301}x'")
    }

    @Test
    func aQuoteAfterAPrependCharacterIsEscaped() {
        #expect(ShellWord.quoted("x\u{600}'y") == "'x\u{600}'\\''y'")
    }

    @Test
    func aNonAsciiLetterIsQuotedNotTrusted() {
        #expect(ShellWord.quoted("caf\u{E9}") == "'caf\u{E9}'")
    }
}
