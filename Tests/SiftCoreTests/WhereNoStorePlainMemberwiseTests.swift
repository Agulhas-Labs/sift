//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A plain `where` of a stored property with no index store counts the calls passing it by its label to its struct's memberwise initializer, so it never says nothing spells a name a call spells.
@Suite(.temporaryDirectories)
struct WhereNoStorePlainMemberwiseTests {
    private static func answer(_ symbol: String, declaring: String, calling: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declaring, to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write(calling, to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions())
    }

    private static var declaring: String {
        "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n"
    }

    @Test
    func aPropertyOnlyPassedByLabelIsCountedNotSaidToBeUnused() async throws {
        let output = try await Self.answer("Gizmo.isReady", declaring: Self.declaring, calling: "func stock() -> Gizmo {\n    Gizmo(weight: 2, isReady: true)\n}\n")

        #expect(output.contains("nothing spelled \"isReady\" is listed here — no use by name, 1 call passing it as isReady: to the memberwise init (--refs lists them)"), "\(output)")
        #expect(!output.contains("anywhere in the working tree"), "\(output)")
        #expect(!output.contains("Gizmo(weight: 2, isReady: true)"), "\(output)")
    }

    @Test
    func aPropertyNoCallPassesStillSaysItIsSpelledNowhere() async throws {
        let output = try await Self.answer("Gizmo.isReady", declaring: Self.declaring, calling: "func stock() -> Gizmo {\n    Gizmo(weight: 2)\n}\n")

        #expect(output.contains("no use spelled \"isReady\" anywhere in the working tree"), "\(output)")
        #expect(!output.contains("memberwise init"), "\(output)")
    }

    @Test
    func aPropertyReadByNameCountsItsLabelCallsBesideTheUses() async throws {
        let calling = "func stock() -> Bool {\n    let gizmo = Gizmo(weight: 2, isReady: true)\n    return gizmo.isReady\n}\n"
        let output = try await Self.answer("Gizmo.isReady", declaring: Self.declaring, calling: calling)

        #expect(output.contains("\"isReady\" (1 use by name, plus 1 call passing it as isReady: to the memberwise init (--refs lists them), in 1 file"), "\(output)")
        #expect(!output.contains("let gizmo = Gizmo(weight: 2, isReady: true)"), "\(output)")
    }
}
