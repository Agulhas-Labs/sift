//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The gate behind a shared fixture's engine lets one body in at a time, however many callers ask at once.
struct SharedFixtureGateTests {
    /// While the first body waits for a second to get in, the second stays outside, so no more than one body is ever inside.
    @Test
    func aSecondCallerWaitsOutsideWhileTheFirstIsInside() async {
        actor Sightings {
            private var inside = 0
            private(set) var mostInside = 0

            func enter() {
                inside += 1
                mostInside = max(mostInside, inside)
            }

            func leave() {
                inside -= 1
            }
        }
        let gate = AsyncGate()
        let sightings = Sightings()
        let firstEntered = AsyncStream<Void>.makeStream()

        async let first: Void = gate.run {
            await sightings.enter()
            firstEntered.continuation.yield()
            for _ in 0 ..< 30 where await sightings.mostInside <= 1 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await sightings.leave()
        }
        var iterator = firstEntered.stream.makeAsyncIterator()
        _ = await iterator.next()
        async let second: Void = gate.run {
            await sightings.enter()
            await sightings.leave()
        }
        _ = await (first, second)

        #expect(await sightings.mostInside == 1)
    }

    /// A body that throws still lets the next caller in.
    @Test
    func aThrowingBodyReleasesTheGate() async {
        struct Failure: Error {}
        let gate = AsyncGate()

        await #expect(throws: Failure.self) {
            try await gate.run { throw Failure() }
        }
        let value = await gate.run { 7 }

        #expect(value == 7)
    }
}
