//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep of a property several structs declare judges a `Self(…)` held for each of them by every one before saying it, so a struct sorted first whose memberwise init cannot take its labels never hides it from one whose init can.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseHeldSelfCallTests {
    @Test
    func aHeldSelfCallTheFirstStructCannotTakeIsListedForTheOneThatCan() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Bag {\n    var size: Int\n}\n", to: "Sources/App/Bag.swift", in: root)
        try TestSources.write("struct Pair {\n    var size: Int\n    var other: Int\n}\n", to: "Sources/App/Pair.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {}

            extension Maker {
                static func make() -> Self { Self(size: 4, other: 5) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)

        let output = try await engine.lookup(symbol: "size", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(output.contains(":4  in Maker.make() (Self(…) on a type the scan cannot tell, which may be Pair)"), "\(output)")
        #expect(output.contains("1 call writing size: to Self(…) on a type the scan cannot tell, which may be Pair, flagged"), "\(output)")
    }
}
