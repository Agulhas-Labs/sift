//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the keying and retry rules of `SharedBuiltFixtures` itself, on a private instance and with populate closures that build nothing.
struct SharedBuiltFixturesHelperTests {
    private static func marker(of fixture: SharedBuiltFixture) throws -> String {
        try String(contentsOf: fixture.root.appendingPathComponent("marker.txt"), encoding: .utf8)
    }

    /// Two suites that pick the same name are two fixtures: the second's `populate` runs and its package is its own.
    @Test
    func aNameReusedByAnotherSuiteGetsItsOwnPackage() async throws {
        let fixtures = SharedBuiltFixtures()

        let first = try await fixtures.fixture(for: SharedBuiltFixturesHelperTests.self, named: "shared-name") { root in
            try TestSources.write("first", to: "marker.txt", in: root)
        }
        let second = try await fixtures.fixture(for: Counter.self, named: "shared-name") { root in
            try TestSources.write("second", to: "marker.txt", in: root)
        }

        #expect(try Self.marker(of: first) == "first")
        #expect(try Self.marker(of: second) == "second")
        #expect(first.root != second.root)
    }

    /// The same suite asking again for the same name still shares one build.
    @Test
    func theSameSuiteAndNameShareOneBuild() async throws {
        let fixtures = SharedBuiltFixtures()
        let builds = Counter()

        let first = try await fixtures.fixture(for: Self.self, named: "once") { root in
            try TestSources.write("build \(builds.next())", to: "marker.txt", in: root)
        }
        let again = try await fixtures.fixture(for: Self.self, named: "once") { root in
            try TestSources.write("build \(builds.next())", to: "marker.txt", in: root)
        }

        #expect(first.root == again.root)
        #expect(try Self.marker(of: again) == "build 1")
    }

    /// A build that throws is not kept: the next ask runs `populate` again rather than replaying the failure.
    @Test
    func aFailedBuildIsRetriedByTheNextAsk() async throws {
        let fixtures = SharedBuiltFixtures()
        let attempts = Counter()

        await #expect(throws: PopulateFailure.self) {
            _ = try await fixtures.fixture(for: Self.self, named: "flaky") { _ in
                _ = attempts.next()
                throw PopulateFailure()
            }
        }
        let retried = try await fixtures.fixture(for: Self.self, named: "flaky") { root in
            try TestSources.write("attempt \(attempts.next())", to: "marker.txt", in: root)
        }

        #expect(try Self.marker(of: retried) == "attempt 2")
    }
}

extension SharedBuiltFixturesHelperTests {
    struct PopulateFailure: Error {}

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
