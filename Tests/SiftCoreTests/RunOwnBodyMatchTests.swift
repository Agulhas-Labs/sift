//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers which failures a run's answer says are inside their own test, and how it spells the path it says so with.
///
/// A failure in the failing test's own body is worded as a range beside the resolved path; a failure in anything else keeps its `in … (syntactic)` line, because the reader's question there is which declaration, not where the test is.
@Suite(.temporaryDirectories)
struct RunOwnBodyMatchTests {
    /// A helper that shares its base name with the failing test is not the test, so it keeps the `in … (syntactic)` line.
    @Test
    func aHelperSharingTheTestsNameIsNotItsOwnBody() async throws {
        let root = try await Self.indexedRepo(Self.helperSource)
        let location = "DepotStoreTests.swift:11:9"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let answer = Self.answer(Self.swiftTestingLog(at: location), sites: sites, in: root)

        #expect(answer.contains { $0.contains("in Helper.check()") && $0.contains("(syntactic)") })
        #expect(!answer.contains { $0.contains("(body :") })
    }

    /// A failure inside the test's own `@Test` body still gets the range form when a helper elsewhere shares the name.
    @Test
    func theTestItselfStillGetsItsBodyRangeBesideAHelperOfTheSameName() async throws {
        let root = try await Self.indexedRepo(Self.helperSource)
        let location = "DepotStoreTests.swift:19:9"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let answer = Self.answer(Self.swiftTestingLog(at: location), sites: sites, in: root)

        #expect(answer[1] == "  check() — \(Self.path):19 (body :16-21)")
    }

    /// The heading's path is stated as the answer states paths, so it resolves from the directory the run was started in and not only from the repository root.
    @Test
    func theBodyHeadingsPathResolvesFromTheDirectoryTheRunStartedIn() async throws {
        let root = try await Self.indexedRepo(Self.helperSource)
        let location = "DepotStoreTests.swift:19:9"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let log = Self.swiftTestingLog(at: location)

        let inside = Self.answer(log, sites: sites, in: root.appendingPathComponent("Tests"))
        #expect(inside[1] == "  check() — LibTests/DepotStoreTests.swift:19 (body :16-21)")

        let beside = Self.answer(log, sites: sites, in: root.appendingPathComponent("Sources"))
        #expect(beside[1] == "  check() — \(root.path)/\(Self.path):19 (body :16-21)")
    }

    /// An XCTest failure in the method the log names gets the range form, the class read out of `-[Module.Class method]`.
    @Test
    func anXCTestFailureInItsOwnMethodNamesTheBodyOnItsHeading() async throws {
        let root = try await Self.indexedRepo(Self.xctestSource)
        let location = "\(root.path)/\(Self.path):10"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let answer = Self.answer(Self.xctestLog(at: location), sites: sites, in: root)

        #expect(answer.contains("  -[LibTests.DepotStoreTests testDoubling] — \(Self.path):10 (body :8-12)"))
        #expect(!answer.contains { $0.contains("(syntactic)") })
    }

    /// The same method name on another class is not the test the log names, so it keeps the `in … (syntactic)` line.
    @Test
    func anXCTestFailureInAnotherClassSharingTheMethodNameIsNotItsOwnBody() async throws {
        let root = try await Self.indexedRepo(Self.xctestSource)
        let location = "\(root.path)/\(Self.path):17"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let answer = Self.answer(Self.xctestLog(at: location), sites: sites, in: root)

        #expect(answer.contains { $0.contains("in Helper.testDoubling()") && $0.contains("(syntactic)") })
        #expect(!answer.contains { $0.contains("(body :") })
    }
}

private extension RunOwnBodyMatchTests {
    static var path: String {
        "Tests/LibTests/DepotStoreTests.swift"
    }

    /// A helper `Helper.check()` on lines 8-12 failing on line 11, and a `@Test func check()` on lines 16-21 failing on line 19.
    static var helperSource: String {
        """
        //
        // Copyright © Agulhas Labs
        //

        import Testing

        struct Helper {
            func check() {
                let depot = [1]
                _ = depot
                #expect(Bool(false))
            }
        }

        struct DepotStoreTests {
            @Test
            func check() {
                let depot = [1]
                #expect(Bool(false))
                _ = depot
            }
        }

        """
    }

    /// An XCTest case whose `testDoubling` spans lines 8-12 and fails on 10, and a class of another name with a method of the same name failing on 17.
    static var xctestSource: String {
        """
        //
        // Copyright © Agulhas Labs
        //

        import XCTest

        final class DepotStoreTests: XCTestCase {
            func testDoubling() {
                let depot = [1]
                XCTAssertTrue(depot.isEmpty)
                _ = depot
            }
        }

        final class Helper {
            func testDoubling() {
                XCTFail("never")
            }
        }

        """
    }

    static func xctestLog(at location: String) -> [String] {
        [
            "\(location): error: -[LibTests.DepotStoreTests testDoubling] : XCTAssertTrue failed",
            "Executed 1 test, with 1 failure (0 unexpected) in 0.010 (0.010) seconds",
        ]
    }

    static func swiftTestingLog(at location: String) -> [String] {
        [
            "✘ Test check() recorded an issue at \(location): Expectation failed: Bool(false)",
            "✘ Test run with 1 test in 1 suite failed after 0.010 seconds with 1 issue.",
        ]
    }

    static func indexedRepo(_ source: String) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: path, in: root)
        try TestSources.commitAll(in: root, message: "sources")
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    static func answer(_ log: [String], sites: RunFailureSites, in directory: URL) -> [String] {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in log {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        return RunReportRenderer(kind: .swiftTest, workingDirectory: directory, changedFiles: .of([]), sites: sites)
            .render(report, exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
