//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A capped listing that holds the calls passing a stored property by its label does not call the hidden ones uses: they may be either.
@Suite(.temporaryDirectories)
struct WhereCappedLabelCallsTests {
    private static func capped(labelCalls: Int) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    var isReady: Bool\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        for index in 0 ..< 3 {
            try TestSources.write("func read\(index)(_ gizmo: Gizmo) -> Bool {\n    gizmo.isReady\n}\n", to: "Sources/App/Read\(index).swift", in: root)
        }
        for index in 0 ..< labelCalls {
            try TestSources.write("func build\(index)() -> Gizmo {\n    Gizmo(isReady: true)\n}\n", to: "Sources/App/Build\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "capped listing fixture")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(
            symbol: "Gizmo.isReady",
            freshness: engine.ensureFresh(),
            options: WhereOptions(includeSemantic: false, includeReferences: true, nameMatchedSiteCap: 2)
        )
    }

    @Test
    func theHiddenLabelCallsAreNotCalledUses() async throws {
        let output = try await Self.capped(labelCalls: 3)

        #expect(output.contains("    truncated: 4 more uses or calls passing the label"), "\(output)")
    }

    /// The control: with no call passing the label, what is hidden is uses, and is called so.
    @Test
    func withNoLabelCallsTheHiddenSitesAreUses() async throws {
        let output = try await Self.capped(labelCalls: 0)

        #expect(output.contains("    truncated: 1 more uses"), "\(output)")
        #expect(!output.contains("passing the label"), "\(output)")
    }
}
