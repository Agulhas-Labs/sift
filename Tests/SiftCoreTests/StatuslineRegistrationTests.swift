//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers recognising this tool's status-line command, the one test the removal of an older install's status line goes by.
struct StatuslineRegistrationTests {
    @Test
    func ourCommandIsRecognisedAtAnyPathAndOthersAreNot() {
        #expect(StatuslineRegistration.isOurs("/anywhere/sift statusline"))
        #expect(StatuslineRegistration.isOurs("~/.claude/statusline.sh") == false)
        #expect(StatuslineRegistration.isOurs("/anywhere/sift session-start") == false)
        #expect(StatuslineRegistration.isOurs(nil) == false)
    }
}
