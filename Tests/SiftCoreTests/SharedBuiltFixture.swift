//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore

/// A built fixture repository and the engine already warmed over it, shared by every test in a suite that only reads it.
struct SharedBuiltFixture: Sendable {
    /// The repository's root, removed when the process exits.
    let root: URL

    private let engine: SiftEngine
    private let gate = AsyncGate()

    init(root: URL, engine: SiftEngine) {
        self.root = root
        self.engine = engine
    }

    /// Runs `body` with the engine over `root`, its semantic store already loaded, one body at a time whichever suite asks.
    func withEngine<T>(_ body: (SiftEngine) async throws -> T) async throws -> T {
        try await gate.run { try await body(engine) }
    }
}
