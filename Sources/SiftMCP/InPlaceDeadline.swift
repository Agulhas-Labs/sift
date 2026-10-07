//
// Copyright © Agulhas Labs
//

import Foundation

/// How `InPlaceAnswerer.settle` turns a time budget into the instant it stops waiting for a computed answer.
public struct InPlaceDeadline: Sendable {
    private let make: @Sendable (TimeInterval) -> DispatchTime

    public init(_ make: @escaping @Sendable (TimeInterval) -> DispatchTime) {
        self.make = make
    }

    /// `timeBudget` seconds from now: what every production caller is held to.
    public static let wallClock = InPlaceDeadline { .now() + $0 }

    /// Never arrives, whatever `timeBudget` is asked: a test pinning a shape's own break-even arithmetic waits however long the machine takes to compute it, rather than racing a real clock a busy machine can lose.
    public static let unbounded = InPlaceDeadline { _ in .distantFuture }

    /// The instant `settle` waits until, having been given `timeBudget` seconds to spend.
    func instant(after timeBudget: TimeInterval) -> DispatchTime {
        make(timeBudget)
    }
}
