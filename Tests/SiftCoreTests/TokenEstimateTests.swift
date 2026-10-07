//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the token estimate: the ladder it renders at, the ratio it floors at, and the basis it states.
struct TokenEstimateTests {
    /// The same three-significant-figure ladder as `ByteSize.short`, so a reader used to one recognises the other.
    @Test func theLadder() {
        #expect(TokenEstimate.short(bytes: 3200) == "~800 tokens")
        #expect(TokenEstimate.short(bytes: 18000) == "~4.5k tokens")
        #expect(TokenEstimate.short(bytes: 216_000) == "~54k tokens")
        #expect(TokenEstimate.short(bytes: 8_700_000) == "~2.2M tokens")
    }

    /// A lower bytes-per-token ratio would claim more tokens than were actually measured, so the estimate stays at the floor.
    @Test func theEstimateIsAFloor() {
        #expect(TokenEstimate.bytesPerToken == 4)
        #expect(TokenEstimate.tokens(forBytes: 20000) == 5000)
    }

    /// A saving too small to reach a whole token is reported as one, not as none.
    ///
    /// Both callers gate on the saving being positive before asking, so `~0 tokens` is a sentence the tool only ever prints about something it has just established is not zero — as the figure the status line leads with. Nothing is still nothing.
    @Test func aSavingBelowOneTokenIsNotReportedAsNone() {
        #expect(TokenEstimate.short(bytes: 1) == "<1 token")
        #expect(TokenEstimate.short(bytes: 3) == "<1 token")
        #expect(TokenEstimate.short(bytes: 4) == "~1 tokens")
        #expect(TokenEstimate.short(bytes: 0) == "~0 tokens")
    }

    /// The basis names both the measured bytes and the ratio, so the estimate can be checked rather than trusted.
    @Test func theBasisNamesTheMeasuredBytesAndTheRatio() {
        #expect(TokenEstimate.basis(bytes: 8_700_000) == "8.7 MB gross at 4 bytes a token")
    }
}
