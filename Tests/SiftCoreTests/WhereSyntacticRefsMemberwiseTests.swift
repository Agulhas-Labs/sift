//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` answer that is no sweep by name, as `--syntactic` makes it, lists the calls passing a stored property by its label to its struct's memberwise initializer rather than pointing at `--refs`, which was already asked.
@Suite(.temporaryDirectories)
struct WhereSyntacticRefsMemberwiseTests {
    @Test
    func syntacticRefsListsTheLabelCallsItCounts() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("func stock() -> Gizmo {\n    Gizmo(weight: 2, isReady: true)\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Gizmo.isReady", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false, includeReferences: true))

        #expect(output.contains("\"isReady\" (no use by name, 1 call passing it as isReady: to the memberwise init, in 1 file):"), "\(output)")
        #expect(output.contains("    :2  in stock()  | Gizmo(weight: 2, isReady: true)"), "\(output)")
        #expect(!output.contains("lists them"), "\(output)")
    }
}
