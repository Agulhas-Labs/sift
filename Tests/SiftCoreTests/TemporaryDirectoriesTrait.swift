//
// Copyright © Agulhas Labs
//

import Testing

/// Runs each test case in its own `TemporaryDirectory` scope, so every directory it made is gone when it ends.
///
/// The test's own `defer`s run first; a directory that will not go afterwards is recorded against the test. Kept byte-identical in both test targets, like the helper it serves.
struct TemporaryDirectoriesTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    /// One scope per test case, and none for the suite itself: a directory outlives only the case that made it.
    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase _: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await TemporaryDirectory.withScope(sourceLocation: test.sourceLocation) {
            try await function()
        }
    }
}

extension Trait where Self == TemporaryDirectoriesTrait {
    /// Every test case in the suite gets its own `TemporaryDirectory` scope.
    static var temporaryDirectories: Self {
        Self()
    }
}
