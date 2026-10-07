//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A memberwise initializer's sweep counts a `Self(x)` in an extension of a type declared elsewhere only where its labels may reach the struct's initializers: one the memberwise init cannot take is no call of it, and counting every such call in the repository beside it buried the answer and said "may be" of calls the store records as another type's.
@Suite(.temporaryDirectories)
struct WhereMemberwiseSelfCallTests {
    @Test
    func aSelfCallWhoseLabelsTheMemberwiseInitCannotTakeIsLeftOutAndOneItCanIsCounted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Solo {\n    var only: Int\n}\n", to: "Sources/App/Solo.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {
                init(size: Int)
            }

            extension Maker {
                static func make() -> Self { Self(size: 1) }
                static func again() -> Self { Self.init(size: 2) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.write("extension Maker {\n    static func spare() -> Self { Self(only: 3) }\n}\n", to: "Sources/App/Spare.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await WhereInitializerCallsTests.lookup("Solo.init", in: root)

        #expect(output.contains("but Self(…) in an extension is called once with those labels on a type the scan cannot tell, any of which may be Solo's"), "\(output)")
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output)
        #expect(rows.contains("  Sources/App/Spare.swift:2  in Maker.spare()"), "\(output)")
        #expect(!output.contains("in Maker.make()"), "\(output)")
        #expect(!output.contains("in Maker.again()"), "\(output)")
    }
}
