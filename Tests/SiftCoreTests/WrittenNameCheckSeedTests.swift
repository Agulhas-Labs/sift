//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Pins whose word decides, among several asked declarations of one name, whether a type is listed through an alias: the first whose fold accepts the alias, since every such one holds the same references to it.
struct WrittenNameCheckSeedTests {
    /// A class row standing for a type whose clause writes an alias.
    private static var row: SymbolRow {
        SymbolRow(
            id: 1, fileID: 1, path: "Sources/App/App.swift", module: "App", parentID: nil, kind: .classKind, name: "Guest",
            line: 1, column: 1, endLine: 1, accessLevel: .internalLevel, isStatic: false, isStored: false,
            signature: "class Guest: Footing", docSummary: nil, ifConfigCondition: nil, viewOutline: nil
        )
    }

    /// The first asked declaration whose fold accepts the alias decides, over a later one that disagrees.
    @Test
    func theFirstAcceptingDeclarationDecides() {
        var check = WhereRenderer.WrittenNameCheck()
        check.addSeeds(spellings: ["Lib.Footing"]) { _, _ in false }
        check.addSeeds(spellings: ["Lib.Footing"]) { _, _ in true }

        #expect(check.seeds(Self.row, through: "Lib.Footing") == false)
    }

    /// A declaration whose fold does not accept the alias has no say, so a later one that does decides.
    @Test
    func aDeclarationNotAcceptingTheAliasIsPassedOver() {
        var check = WhereRenderer.WrittenNameCheck()
        check.addSeeds(spellings: ["Other.Footing"]) { _, _ in false }
        check.addSeeds(spellings: ["Lib.Footing"]) { _, _ in true }

        #expect(check.seeds(Self.row, through: "Lib.Footing") == true)
    }

    /// Where no declaration's fold accepts the alias, the store cannot speak for the type.
    @Test
    func noAcceptingDeclarationCannotSpeak() {
        var check = WhereRenderer.WrittenNameCheck()
        check.addSeeds(spellings: ["Other.Footing"]) { _, _ in false }

        #expect(check.seeds(Self.row, through: "Lib.Footing") == nil)
    }
}
