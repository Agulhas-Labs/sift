//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` answer given while the store is still loading, or after it failed to open, is no sweep by name either, so it lists the calls passing a stored property by its label to its struct's memberwise initializer rather than pointing at `--refs`, which was already asked.
@Suite(.temporaryDirectories)
struct WhereLabelCallsUnansweredStoreTests {
    @Test(arguments: [Store.loading, Store.failed])
    private func theLabelCallsAreListedBesideAStoreThatAnsweredNothing(store: Store) async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("func stock() -> Gizmo {\n    Gizmo(weight: 2, isReady: true)\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "store that has not answered")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let engine = try SiftEngine(directory: root)
        if store == .loading {
            engine.openBudget = 0
        }
        let freshness = try await engine.ensureFresh()
        if store == .failed {
            try Data("not a directory".utf8).write(to: SiftPaths.cache(in: root).appendingPathComponent("isdb"))
        }

        let output = try await engine.lookup(symbol: "Gizmo.isReady", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(output.contains(store == .loading ? "still warming" : "failed to open"), "\(output)")
        #expect(output.contains("\"isReady\" (no use by name, 1 call passing it as isReady: to the memberwise init, in 1 file):"), "\(output)")
        #expect(output.contains("    :2  in stock()  | Gizmo(weight: 2, isReady: true)"), "\(output)")
        #expect(!output.contains("lists them"), "\(output)")
    }
}

extension WhereLabelCallsUnansweredStoreTests {
    private enum Store {
        case loading
        case failed
    }
}
