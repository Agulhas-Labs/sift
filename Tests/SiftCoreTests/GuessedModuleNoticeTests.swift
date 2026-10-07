//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers ``GuessedModuleNotice``'s own text: the banner it opens an answer on, and ``GuessedModuleNotice/hoisted(from:)``, which reads that banner back out of a compound answer's parts.
struct GuessedModuleNoticeTests {
    /// `hoisted` used to split a banner's named paths on a bare space, so a guessed path holding one counted as two files rather than one.
    @Test
    func hoistedKeepsASpacedGuessedPathWhole() throws {
        let banner = try #require(GuessedModuleNotice(paths: ["Sources/My App/A.swift"]).banner)

        let (answers, hoisted) = GuessedModuleNotice.hoisted(from: ["\(banner)\n\nbody"])

        #expect(answers == ["body"])
        #expect(hoisted?.contains("Sources/My App/A.swift") == true)
        #expect(hoisted?.contains("(+1 more)") != true)
    }
}
