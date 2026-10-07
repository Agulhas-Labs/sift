//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Builds each read-only fixture once per process, so a suite of tests over one built package pays for one `swift build` instead of one per test.
///
/// A fixture is built the first time a test asks for its name and every later ask, concurrent or not, awaits that same build. Only a fixture no test mutates belongs here: the engine is shared too, since two engines over one root would write the same `.sift` index at once, and an engine is not safe to query from two threads at once, so the fixture hands it out only through `withEngine`, which runs one body at a time for every caller in the process, whichever suite it is in.
actor SharedBuiltFixtures {
    static let process = SharedBuiltFixtures()

    private var builds: [String: Task<SharedBuiltFixture, Error>] = [:]

    /// The fixture filed under `name` for `suite`, made by `populate` (which writes, commits and builds inside the fresh repository) on the first ask.
    ///
    /// The key is the suite's type as well as the name, so two suites that pick the same name each get their own package rather than the first one built. A build that throws is dropped, so the next ask runs `populate` again instead of replaying the same failure.
    func fixture(
        for suite: Any.Type,
        named name: String,
        populate: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> SharedBuiltFixture {
        let key = "\(String(reflecting: suite))/\(name)"
        if let existing = builds[key] {
            return try await value(of: existing, key: key)
        }
        let build = Task.detached {
            try await TemporaryDirectory.withScope {
                let root = try TestSources.makeTempRepo(at: TemporaryDirectory.makeForProcess("shared-\(name)"))
                try await populate(root)
                let engine = try SiftEngine(directory: root)
                TestSources.raiseOpenBudgetForAColdStore(engine)
                try await engine.awaitSemanticStore()
                return SharedBuiltFixture(root: root, engine: engine)
            }
        }
        builds[key] = build
        return try await value(of: build, key: key)
    }

    /// Awaits `build`, and on failure forgets it (unless a retry already replaced it) so a later ask starts over.
    private func value(of build: Task<SharedBuiltFixture, Error>, key: String) async throws -> SharedBuiltFixture {
        do {
            return try await build.value
        } catch {
            if builds[key] == build {
                builds[key] = nil
            }
            throw error
        }
    }
}
