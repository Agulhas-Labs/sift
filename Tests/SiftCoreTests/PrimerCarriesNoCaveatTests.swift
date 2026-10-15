//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The session-start primer carries no standing caveat for any audience: it is said on an answer only where it applies (`CaveatWhereItAppliesTests`).
struct PrimerCarriesNoCaveatTests {
    @Test
    func theSessionPrimerDoesNotCarryTheStandingCaveats() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .session))

        #expect(!primer.contains(StandingCaveats.sentences))
    }

    @Test
    func theSubagentPrimerCarriesNoStandingCaveats() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .subagent))

        #expect(!primer.contains(StandingCaveats.sentences))
    }

    @Test
    func theServerAbsentPrimerCarriesNoStandingCaveats() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .session, serverAbsent: true))

        #expect(!primer.contains(StandingCaveats.sentences))
    }
}
