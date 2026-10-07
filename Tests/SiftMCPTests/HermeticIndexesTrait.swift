//
// Copyright © Agulhas Labs
//

import SiftCore
import Testing

/// Runs each test case with no repositories registered, so a `RunIndexState` it makes without a registry of its own does not read this machine's `~/.sift/roots.json`.
///
/// A test that expects "no index declares X" otherwise flips with what the machine's real repositories hold. A test that registers roots passes its own registry, which wins.
struct HermeticIndexesTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    /// One scope per test case, and none for the suite itself.
    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for _: Test, testCase _: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let noRoots: @Sendable () -> [String] = { [] }
        try await RunIndexState.$scopedRegistry.withValue(noRoots) {
            try await function()
        }
    }
}

extension Trait where Self == HermeticIndexesTrait {
    /// Every test case in the suite sees an empty machine registry unless it passes its own.
    static var hermeticIndexes: Self {
        Self()
    }
}
