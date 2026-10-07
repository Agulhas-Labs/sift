//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers resolving a failure in a file written since the index was last brought up to date — the test file just written to prove a fix, before anyone has run `git add` on it.
///
/// `run` opens the index read-only and never refreshes it, so a file the index has not seen yet is one it cannot name. The file most likely to hold a new failure is exactly that one, and git already knows it is there: untracked and not ignored is a file the next refresh will index, so it resolves now. An ignored file never will, and stays unresolved.
@Suite(.temporaryDirectories)
struct RunFailureSitesUntrackedTests {
    /// An untracked, unignored file resolves like an indexed one, so its heading carries the repo-relative path and the body range.
    @Test
    func aFailureInAnUntrackedFileResolvesLikeOneInATrackedFile() async throws {
        let root = try await Self.indexedRepo()
        try TestSources.write(Self.depotSource, to: Self.depotPath, in: root)

        let sites = RunFailureSites.resolving([Self.location], inRepositoryAt: root)
        let declaration = try #require(sites.declaration(at: Self.location))

        #expect(declaration.name == "DepotStoreTests.aFailingTest()")
        #expect(declaration.path == Self.depotPath)
        #expect(declaration.startLine == 8)
        #expect(declaration.endLine == 12)
        #expect(Self.answer(at: Self.location, sites: sites, in: root).dropFirst().first == "  aFailingTest() — \(Self.depotPath):11 (body :8-12)")
    }

    /// A failure in a helper beside the test gets its `in … (syntactic)` line when the file is untracked, as it does once added.
    @Test
    func aHelperInAnUntrackedFileGetsItsSiteLine() async throws {
        let root = try await Self.indexedRepo()
        try TestSources.write(Self.depotSource, to: Self.depotPath, in: root)
        let helper = "DepotStoreTests.swift:17:9"

        let sites = RunFailureSites.resolving([helper], inRepositoryAt: root)

        #expect(Self.answer(at: helper, sites: sites).contains("    in DepotStoreTests.restock() — \(Self.depotPath):16-18 (syntactic)"))
    }

    /// Git's ignore rules keep a file out of the index for good, so a failure printed in one stays unresolved — as it always has.
    @Test
    func aFailureInAnIgnoredFileStaysUnresolved() async throws {
        let root = try await Self.indexedRepo()
        try TestSources.write("Tests/Scratch/\n", to: ".gitignore", in: root)
        try TestSources.write(Self.depotSource, to: "Tests/Scratch/DepotStoreTests.swift", in: root)

        let sites = RunFailureSites.resolving([Self.location], inRepositoryAt: root)

        #expect(sites.declaration(at: Self.location) == nil)
        let answer = Self.answer(at: Self.location, sites: sites)
        #expect(answer.dropFirst().first == "  aFailingTest() — \(Self.location)")
        #expect(!answer.contains { $0.contains("(syntactic)") })
    }

    /// Once the index has caught up the file is in its table as well as untracked on disk, which is one file and not two same-named ones.
    @Test
    func anUntrackedFileTheIndexAlreadyHoldsIsNotCountedTwice() async throws {
        let root = try await Self.indexedRepo()
        try TestSources.write(Self.depotSource, to: Self.depotPath, in: root)
        try await SiftEngine(directory: root).ensureFresh()

        let sites = RunFailureSites.resolving([Self.location], inRepositoryAt: root)

        #expect(sites.declaration(at: Self.location)?.path == Self.depotPath)
    }

    /// An untracked file sharing its name with an indexed one is as ambiguous as two tracked ones, and resolves to neither.
    @Test
    func anUntrackedFileNamedLikeAnIndexedOneResolvesToNeither() async throws {
        let root = try await Self.indexedRepo(extraFiles: [Self.depotPath: Self.depotSource])
        try TestSources.write(Self.depotSource, to: "Tests/OtherTests/DepotStoreTests.swift", in: root)

        let sites = RunFailureSites.resolving([Self.location], inRepositoryAt: root)

        #expect(sites.declaration(at: Self.location) == nil)
    }
}

private extension RunFailureSitesUntrackedTests {
    static var depotPath: String {
        "Tests/LibTests/DepotStoreTests.swift"
    }

    /// Where Swift Testing prints the failing `#expect` in ``depotSource``: a bare filename, line 11.
    static var location: String {
        "DepotStoreTests.swift:11:9"
    }

    /// A test whose body spans lines 8-12 and holds the failing expectation on line 11, and a helper on lines 16-18.
    static var depotSource: String {
        """
        //
        // Copyright © Agulhas Labs
        //

        import Testing

        struct DepotStoreTests {
            @Test
            func aFailingTest() {
                let depot = [1]
                #expect(depot.isEmpty)
            }
        }

        extension DepotStoreTests {
            func restock() {
                #expect(Bool(false))
            }
        }

        """
    }

    /// A committed, indexed repository holding one unrelated source (and anything else asked for).
    static func indexedRepo(extraFiles: [String: String] = [:]) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Lib {}\n", to: "Sources/Lib/Lib.swift", in: root)
        for (path, source) in extraFiles {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "sources")
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The answer a plain `swift test` gives one failure of `aFailingTest()` printed at `location`, line by line.
    static func answer(at location: String, sites: RunFailureSites, in directory: URL = URL(fileURLWithPath: "/Users/dev/Widget")) -> [String] {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in [
            "✘ Test aFailingTest() recorded an issue at \(location): Expectation failed: depot.isEmpty",
            "✘ Test run with 1 test in 1 suite failed after 0.010 seconds with 1 issue.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)
        return RunReportRenderer(kind: .swiftTest, workingDirectory: directory, changedFiles: .of([]), sites: sites)
            .render(report, exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
