//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` sweep of a stored property with no index store lists the calls passing it by its label to its struct's memberwise initializer, since a rename of the property changes every one of those labels.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseLabelTests {
    private static func answer(_ symbol: String, declaring: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declaring, to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("func stock() -> Bool {\n    let gizmo = Gizmo(weight: 2, isReady: true)\n    return gizmo.isReady\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    @Test
    func aMemberwiseLabelInsideAndOutsideTheTypeIsListed() async throws {
        let declaring = "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n\nextension Gizmo {\n    static let spare = Gizmo(weight: 1, isReady: false)\n}\n"
        let output = try await Self.answer("Gizmo.isReady", declaring: declaring)

        #expect(output.contains("references: all sites by written name, paged by file"), "\(output)")
        #expect(output.contains("\"isReady\" (1 use by name, plus 2 calls passing it as isReady: to the memberwise init, in 2 files"), "\(output)")
        #expect(output.contains(":7  in Gizmo.spare  | static let spare = Gizmo(weight: 1, isReady: false)"), "\(output)")
        #expect(output.contains(":2  in stock().gizmo  | let gizmo = Gizmo(weight: 2, isReady: true)"), "\(output)")
        #expect(output.contains(":3  in stock()  | return gizmo.isReady"), "\(output)")
    }

    /// A struct that declares its own initializer has no memberwise one, so a label at its calls is that initializer's parameter, not the property.
    @Test
    func aStructDeclaringItsOwnInitHasNoMemberwiseLabelsToList() async throws {
        let declaring = "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n\n    init(weight: Int, isReady: Bool) {\n        self.weight = weight\n        self.isReady = isReady\n    }\n}\n"
        let output = try await Self.answer("Gizmo.isReady", declaring: declaring)

        #expect(!output.contains("to the memberwise init"), "\(output)")
        #expect(!output.contains("let gizmo = Gizmo(weight: 2, isReady: true)"), "\(output)")
        #expect(output.contains(":3  in stock()  | return gizmo.isReady"), "\(output)")
    }
}
