//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the source-literal listing of `strings` — production sites listed, test sites counted per file, and a test-only match listed as before.
@Suite(.temporaryDirectories)
struct StringsTestSitesTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "test sites fixture")
        return try SiftEngine(directory: root)
    }

    private static var productionStore: String {
        """
        struct Depot {
            func label() -> String {
                "a gizmo label"
            }
        }
        """
    }

    private static func testStore(name: String, sites: Int) -> String {
        let bodies = (0 ..< sites).map { "    func check\($0)() { _ = \"gizmo \($0)\" }" }
        return "import Testing\nstruct \(name) {\n" + bodies.joined(separator: "\n") + "\n}\n"
    }

    @Test
    func productionSitesAreListedAndTestSitesCountedPerFile() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/Depot.swift": Self.productionStore,
            "Tests/Depot/AlphaTests.swift": Self.testStore(name: "AlphaTests", sites: 2),
            "Tests/Depot/BetaTests.swift": Self.testStore(name: "BetaTests", sites: 3),
        ])

        let output = try engine.strings(query: "gizmo")

        #expect(output.contains("Sources/Depot/Depot.swift:3"))
        #expect(!output.contains("Tests/Depot/AlphaTests.swift:"))
        #expect(output.contains("in tests: 5 sites in 2 files — AlphaTests.swift (2), BetaTests.swift (3)"))
    }

    @Test
    func theTestLineSaysItWasSplitOnTheImportNotThePath() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/Depot.swift": Self.productionStore,
            "Tests/Depot/Alpha.swift": Self.testStore(name: "Alpha", sites: 1),
        ])

        let output = try engine.strings(query: "gizmo")

        #expect(output.contains("in tests: 1 site in 1 file — Alpha.swift (1), split on the XCTest or Testing import, never the path"))
    }

    @Test
    func filesSharingANameAreToldApartByTheirDirectory() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/Depot.swift": Self.productionStore,
            "Tests/Alpha/Foo.swift": Self.testStore(name: "Foo", sites: 2),
            "Tests/Beta/Foo.swift": Self.testStore(name: "Foo", sites: 1),
            "Tests/Beta/Bar.swift": Self.testStore(name: "Bar", sites: 1),
        ])

        let output = try engine.strings(query: "gizmo")

        #expect(output.contains("Alpha/Foo.swift (2), Bar.swift (1), Beta/Foo.swift (1)"))
    }

    @Test
    func productionSitesSortingAfterMoreThanACapOfTestSitesAreStillListed() throws {
        let engine = try Self.makeRepo(files: [
            "Alpha/Gizmo.swift": Self.testStore(name: "Gizmo", sites: SourceLiteralSearch.siteCap + 2),
            "Sources/Depot/Depot.swift": Self.productionStore,
        ])

        let output = try engine.strings(query: "gizmo")

        #expect(output.contains("Depot.label() — Sources/Depot/Depot.swift:3"))
        #expect(!output.contains("more — narrow the query"))
        #expect(output.contains("in tests: 22 sites in 1 file — Gizmo.swift (22)"))
    }

    @Test
    func aQueryMatchingOnlyTestSitesListsThemWithNoCountLine() throws {
        let engine = try Self.makeRepo(files: [
            "Tests/Depot/AlphaTests.swift": Self.testStore(name: "AlphaTests", sites: 2),
        ])

        let output = try engine.strings(query: "gizmo")

        #expect(output.contains("Tests/Depot/AlphaTests.swift:3"))
        #expect(output.contains("Tests/Depot/AlphaTests.swift:4"))
        #expect(!output.contains("in tests:"))
    }
}
