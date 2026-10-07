//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep of a stored property finds the calls passing it by its label to a memberwise initializer whose labels are less plain to read: a `lazy` property is a parameter with a default, and a struct whose labels cannot be worked out is still scanned and its calls counted.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseUnreadLabelsTests {
    private static func answer(_ symbol: String, declaring: String, using: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declaring, to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write(using, to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A `lazy` property is a memberwise parameter with a default: a call may leave it out or pass it.
    @Test
    func aLazyPropertyIsADefaultedMemberwiseParameter() async throws {
        let declaring = "struct Gizmo {\n    var isReady: Bool\n    lazy var weight = 0\n}\n"
        let using = "func stock() -> Bool {\n    let gizmo = Gizmo(isReady: true)\n    var spare = Gizmo(isReady: false, weight: 3)\n    return gizmo.isReady && spare.weight > 0\n}\n"
        let ready = try await Self.answer("Gizmo.isReady", declaring: declaring, using: using)
        let weight = try await Self.answer("Gizmo.weight", declaring: declaring, using: using)

        #expect(ready.contains("plus 2 calls passing it as isReady: to the memberwise init, in 1 file"), "\(ready)")
        #expect(ready.contains(":2  in stock().gizmo  | let gizmo = Gizmo(isReady: true)"), "\(ready)")
        #expect(ready.contains(":3  in stock().spare  | var spare = Gizmo(isReady: false, weight: 3)"), "\(ready)")
        #expect(weight.contains("plus 1 call passing it as weight: to the memberwise init, in 1 file"), "\(weight)")
        #expect(weight.contains(":3  in stock().spare  | var spare = Gizmo(isReady: false, weight: 3)"), "\(weight)")
    }

    /// A tuple-pattern property leaves the memberwise labels unknown, so a call writing the label is counted with that caveat, and the verdict claims neither absence nor that the call builds nothing.
    @Test
    func aStructWhoseLabelsCannotBeWorkedOutIsStillScannedAndCounted() async throws {
        let declaring = "struct Gizmo {\n    var (weight, spare): (Int, Int)\n    var isReady: Bool\n}\n"
        let using = "func stock() -> [Gizmo] {\n    [\n        Gizmo(weight: 1, spare: 2, isReady: true),\n        Gizmo(weight: 3, spare: 4, isReady: false),\n    ]\n}\n"
        let output = try await Self.answer("Gizmo.isReady", declaring: declaring, using: using)

        #expect(output.contains("nothing spelled \"isReady\" is listed here — "), "\(output)")
        #expect(output.contains("2 calls writing isReady: to Gizmo(…) not listed, as its memberwise labels could not be worked out"), "\(output)")
        #expect(!output.contains("anywhere in the working tree"), "\(output)")
        #expect(!output.contains("builds its type"), "\(output)")
        #expect(!output.contains("| Gizmo(weight: 1"), "\(output)")
    }
}
