//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The count of calls on a type the scan cannot tell beside a memberwise initializer's list says `with those labels`, and is true of it: an implicit `.init` whose labels no asked type's initializers take is left out by the same rule as a held `Self(…)`, so every call counted is written with labels one of them takes.
@Suite(.temporaryDirectories)
struct WhereMemberwiseHeldLabelClaimTests {
    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Solo {\n    var size: Int\n}\n", to: "Sources/App/Solo.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {}

            extension Maker {
                static func one() -> Self { Self(size: 1) }
                static func two() -> Self { Self(size: 2) }
                static func three() -> Self { Self(size: 3) }
                static func four() -> Self { Self(size: 4, only: 5) }
            }

            func made() -> [Any] {
                [make(\(WhereInitializerCallsTests.implied)(size: 6)),
                 make(\(WhereInitializerCallsTests.implied)(only: 7))]
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func theCountOfUntoldCallsSaysItWasNarrowedByLabels() async throws {
        let root = try Self.repo()

        let solo = try await WhereInitializerCallsTests.lookup("Solo.init", in: root)

        #expect(solo.contains("but an implicit .init or Self(…) in an extension is called 4 times with those labels on a type the scan cannot tell, any of which may be Solo's"), "\(solo)")
        #expect(!solo.contains("in Maker.four()"), "\(solo)")
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(solo)
        #expect(rows.contains("Sources/App/Maker.swift:11  in made()"), "\(solo)")
        #expect(!rows.contains("Sources/App/Maker.swift:12  in made()"), "\(solo)")
    }
}
