//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep of a stored property lists a `Self(size: 1)` written in an extension of a type the scan cannot tell flagged as one that may build the struct, counted apart from the calls passing the label to its memberwise init: `Self` there may be any conforming type, so the call is no verified use of the property.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseSelfCallTests {
    private static func answer(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Solo {\n    var size: Int\n}\n", to: "Sources/App/Solo.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {}

            extension Maker {
                static func make() -> Self { Self(size: 1) }
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
    func aSelfCallOnAnUntoldTypeIsFlaggedAndCountedApartFromTheMemberwiseCalls() async throws {
        let output = try await Self.answer("Solo.size")

        #expect(output.contains("1 call writing size: to Self(…) on a type the scan cannot tell, which may be Solo, flagged"), "\(output)")
        #expect(output.contains(":4  in Maker.make() (Self(…) on a type the scan cannot tell, which may be Solo)"), "\(output)")
        #expect(!output.contains("passing it as size: to the memberwise init"), "\(output)")
    }

    /// One whose labels the memberwise init cannot take would not compile on the struct, so it is no call of it: it is not listed, but counted, so the site is never lost unsaid.
    @Test
    func aSelfCallWhoseLabelsTheMemberwiseInitCannotTakeIsLeftOut() async throws {
        let output = try await Self.answer("Solo.size")

        #expect(!output.contains("in Maker.again()"), "\(output)")
        #expect(output.contains("1 writing size: to Self(…) that no asked type's memberwise init takes, not listed"), "\(output)")
    }
}
