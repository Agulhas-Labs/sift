//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A held `Self(…)` writing a stored property's label that no asked struct's memberwise init can take is not listed with the property's uses, but counted, so the site never leaves the answer unsaid; one some asked struct can take is listed for it and counted for none.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseUnfitSelfCallTests {
    private static func answer(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Bag {\n    var size: Int\n}\n", to: "Sources/App/Bag.swift", in: root)
        try TestSources.write("struct Pair {\n    var size: Int\n    var other: Int\n}\n", to: "Sources/App/Pair.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {}

            extension Maker {
                static func make() -> Self { Self(size: 4, other: 5) }
                static func again() -> Self { Self(size: 2, only: 3) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    @Test
    func aHeldCallNoAskedStructCanTakeIsCountedOnce() async throws {
        let output = try await Self.answer("size")

        #expect(output.contains("1 writing size: to Self(…) that no asked type's memberwise init takes, not listed"), "\(output)")
        #expect(!output.contains("in Maker.again()"), "\(output)")
        #expect(output.contains(":4  in Maker.make() (Self(…) on a type the scan cannot tell, which may be Pair)"), "\(output)")
    }

    @Test
    func aHeldCallTheAskedStructCannotTakeIsCountedForIt() async throws {
        let output = try await Self.answer("Bag.size")

        #expect(output.contains("2 calls writing size: to Self(…) that no asked type's memberwise init takes, not listed"), "\(output)")
        #expect(!output.contains("in Maker.make()"), "\(output)")
    }
}
