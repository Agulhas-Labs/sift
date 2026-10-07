//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `where` refusal that covers only some of the listed declarations names the refused ones directly, so "it"/"them" always has a referent to point at — the short and multi-file forms in WhereAnswerTrimTests stay exactly as worded there when every listed declaration was refused.
@Suite(.temporaryDirectories)
struct WhereRefusalNamesTests {
    /// `#if os(Linux)` keeps `go(y:)` out of the macOS build, so the store records no occurrence of it while `go(x:)` in the same file answers normally — the case the finding names: naming the refused overload is the only way "it" points at something.
    @Test
    func aPartiallyRefusedFileNamesTheRefusedDeclaration() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(
            """
            public struct Depot {
                public func go(x: Int) {}
                #if os(Linux)
                public func go(y: Int) {}
                #endif
            }
            """,
            to: "Sources/Lib/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "add Depot")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Depot.go", freshness: freshness)

        #expect(output.contains("declarations (2):"))
        #expect(output.contains("semantic REFUSED for go(y:) — no occurrence recorded in this build; the declaration is under #if os(Linux), which this build may not have compiled"))
        // The answered overload gets its own callers section — the refusal above is not said of it too.
        #expect(output.contains("no callers of Lib.Depot.go(x:) recorded in the store"))
        #expect(!output.contains("REFUSED for go(x:)"))
    }

    /// Every listed declaration refused, sharing one file — the short form drops both the path and the names, exactly as `WhereAnswerTrimTests` pins, even where a `shortName` closure is supplied: naming only matters once the refusal stops covering everything listed.
    @Test
    func allListedRefusedKeepsTheShortFormEvenWithAShortNameClosure() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Base.swift", reason: .noCoveringUnit, symbol: "Lib.Base.init()", kind: .initializer),
        ]

        let lines = SemanticRefusal.lines(
            refusals,
            namingDeclarations: false,
            declarationsSpanMultipleFiles: false,
            allListedRefused: true,
            shortName: { _ in "init()" }
        )

        #expect(lines == [
            "",
            "semantic REFUSED — no unit in the store covers it; build this target, then retry — it may be in a target the last build skipped",
        ])
    }

    /// Two of three listed declarations refused, in two different files, for the same reason — the line names both rather than falling back to "for 2 declarations: their files …", which would say nothing about which two of the three were refused.
    @Test
    func partiallyRefusedAcrossFilesNamesEachOne() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Dogwood.swift", reason: .modifiedSinceBuild, symbol: "Lib.mixed(x:)", kind: .function),
            SemanticRefusal(path: "Sources/Lib/Elm.swift", reason: .modifiedSinceBuild, symbol: "Lib.mixed(y:)", kind: .function),
        ]

        let lines = SemanticRefusal.lines(
            refusals,
            namingDeclarations: false,
            declarationsSpanMultipleFiles: true,
            allListedRefused: false,
            shortName: { $0.symbol == "Lib.mixed(x:)" ? "mixed(x:)" : "mixed(y:)" }
        )

        #expect(lines == [
            "",
            "semantic REFUSED for mixed(x:), mixed(y:) — changed since the last build; build the project, then retry",
        ])
    }
}
