//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the line a refused `--filter` carries when it names a type or function the index declares: the suites that reference it, in the refusal's own answer and beside its unchanged first line and exit code.
@Suite(.serialized, .temporaryDirectories)
struct UnmatchedFilterHintTests {
    private static func manifest() -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    /// `Widget` is named by `LampTests`, `Gadget` by no test, and `Sprocket` by none of the files at all.
    private static func engine() async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\npublic struct Gadget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct LampTests {
                @Test func lights() {
                    _ = Widget()
                }
            }
            """,
            to: "Tests/LibTests/LampTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()
        return engine
    }

    @Test
    func aDeclaredTypeSomeTestNamesGetsTheSuitesThatNameIt() async throws {
        let hint = try #require(await Self.engine().filterHint(named: "Widget"))

        #expect(hint.declaredIn == ["Sources/Lib/Core.swift"])
        #expect(hint.suites == ["LibTests.LampTests"])
        #expect(hint.line == "  Widget is declared in Sources/Lib/Core.swift; suites referencing it: LibTests.LampTests — pass one as --filter")
    }

    @Test
    func anUndeclaredNameGetsNoLine() async throws {
        #expect(try await Self.engine().filterHint(named: "Sprocket") == nil)
    }

    @Test
    func aDeclaredNameNoTestReferencesGetsNoLine() async throws {
        #expect(try await Self.engine().filterHint(named: "Gadget") == nil)
    }

    @Test
    func theLineCapsTheSuitesAndCountsTheRest() throws {
        let suites = (1 ... 8).map { "LibTests.Suite\($0)" }
        let hint = UnmatchedFilterHint(name: "Widget", declaredIn: ["Sources/Lib/Core.swift", "Sources/Lib/More.swift"], suites: suites)
        let line = try #require(hint.line)

        #expect(line.contains("declared in Sources/Lib/Core.swift and 1 more;"))
        #expect(line.contains("LibTests.Suite5, +3 more — pass one as --filter"))
        #expect(!line.contains("Suite6"))
        #expect(UnmatchedFilterHint(name: "Widget", declaredIn: ["Sources/Lib/Core.swift"], suites: []).line == nil)
    }

    /// Only a suite that names the declaration itself is said to reference it; one reached through other code is said to reach it, so the reader does not look for a mention that is not there.
    @Test
    func suitesReachedThroughOtherCodeAreNotSaidToReferenceIt() {
        let core = ["Sources/Lib/Core.swift"]
        let none = UnmatchedFilterHint(name: "Widget", declaredIn: core, suites: ["LibTests.ConveyorBeltTests"], direct: 0).line
        let mixed = UnmatchedFilterHint(name: "Widget", declaredIn: core, suites: ["LibTests.LampTests", "LibTests.ConveyorBeltTests"], direct: 1).line

        #expect(none == "  Widget is declared in Sources/Lib/Core.swift; no suite references it; suites reaching it through other code: LibTests.ConveyorBeltTests — pass one as --filter")
        #expect(mixed == "  Widget is declared in Sources/Lib/Core.swift; suites referencing it: LibTests.LampTests; reaching it through other code: LibTests.ConveyorBeltTests — pass one as --filter")
    }

    @Test(arguments: ["Widget", "_Widget", "Widget2"])
    func aBareIdentifierMayNameADeclaration(pattern: String) {
        #expect(UnmatchedFilterHint.isBareIdentifier(pattern))
    }

    @Test(arguments: ["", "LibTests.LampTests", "LampTests$", "Lamp.*", "2Widget", "a/b", "a b"])
    func aDottedAnchoredOrRegexPatternNamesNoDeclaration(pattern: String) {
        #expect(!UnmatchedFilterHint.isBareIdentifier(pattern))
    }

    @Test
    func anIndexlessCheckoutGetsNoLineAndBuildsNoIndex() throws {
        let root = try TestSources.makeTempRepo()
        let lines = UnmatchedFilterHint.lines(forPatterns: ["Widget"], repositoryRoot: root)

        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path))
    }

    @Test
    func anIndexedCheckoutGetsTheLineFromTheLookupTheRefusalRuns() async throws {
        let root = try await Self.engine().repoRoot
        let lines = UnmatchedFilterHint.lines(forPatterns: ["Widget", "Nothing"], repositoryRoot: root, budget: 30)

        #expect(lines == ["  Widget is declared in Sources/Lib/Core.swift; suites referencing it: LibTests.LampTests — pass one as --filter"])
    }

    /// A file changed after the index was built is a stale note, not a slow one: the lookup answers from the stored index and the index file is exactly as it was.
    @Test
    func aStaleIndexIsReadAsItStandsAndNeverFreshened() async throws {
        let root = try await Self.engine().repoRoot
        let database = SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName)
        let before = try FileManager.default.attributesOfItem(atPath: database.path)
        try TestSources.write("public struct Gadget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)

        let started = Date()
        let lines = UnmatchedFilterHint.lines(forPatterns: ["Widget"], repositoryRoot: root, budget: 30)
        let after = try FileManager.default.attributesOfItem(atPath: database.path)

        #expect(lines.count == 1)
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(after[.size] as? Int == before[.size] as? Int)
    }

    @Test
    func theRefusalAndItsExitCodeAreTheSameWithTheLine() throws {
        let arguments = ["swift", "test", "--filter", "aFailingTest"]
        let report = try TestSources.runReport("swift-test-no-match", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        let directory = URL(fileURLWithPath: "/Users/dev/Widget")
        let plain = RunReportRenderer(kind: .swiftTest, workingDirectory: directory, selector: selector).render(report, exitCode: 0, logURL: nil)
        let hinted = RunReportRenderer(kind: .swiftTest, workingDirectory: directory, selector: selector, inventory: ["  aFailingTest is declared in Sources/Lib/Core.swift; suites referencing it: LibTests.LampTests — pass one as --filter"])
            .render(report, exitCode: 0, logURL: nil)

        #expect(selector.unmatchedPatterns(report, exitCode: 0) == ["aFailingTest"])
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
        #expect(plain.split(separator: "\n").first == hinted.split(separator: "\n").first)
        #expect(hinted.contains("suites referencing it: LibTests.LampTests"))
        #expect(!plain.contains("suites referencing it"))
    }
}
