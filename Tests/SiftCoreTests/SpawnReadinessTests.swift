//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a spawn told to wait for its child to say it is set up: the deadline's clock starts then, and never waits on a child that will not say it.
struct SpawnReadinessTests {
    /// The time a child takes to get ready is not counted against its deadline.
    ///
    /// Only a lower bound on the elapsed time is asserted, so a loaded machine can only make the case slower, never wrong: the child is ready after the first pause and is then ended at the deadline, so the call takes at least both.
    @Test
    func theDeadlineStartsOnceTheChildIsReady() throws {
        let started = ContinuousClock.now
        let output = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "sleep 0.4; echo ready; sleep 60"], deadline: 0.2, ready: "ready")
        let elapsed = ContinuousClock.now - started

        #expect(output.standardError.contains("timed out"), "\(output.standardError)")
        #expect(output.standardError.contains("did not finish within 0.2s of being ready"), "\(output.standardError)")
        #expect(output.standardOutput.contains("ready"), "\(output.standardOutput)")
        #expect(elapsed >= .seconds(0.6), "the call took only \(elapsed)")
    }

    /// A child that exits without ever saying it is ready ends the wait for it at once, rather than at the wait's limit.
    @Test
    func aChildThatExitsWithoutSayingReadyEndsTheWait() throws {
        let started = ContinuousClock.now
        let output = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "echo hello"], deadline: 5, ready: "ready")
        let elapsed = ContinuousClock.now - started

        #expect(output.succeeded, "\(output)")
        #expect(output.standardOutput == "hello\n", "\(output.standardOutput)")
        #expect(elapsed < .seconds(20), "the call took \(elapsed)")
    }
}
