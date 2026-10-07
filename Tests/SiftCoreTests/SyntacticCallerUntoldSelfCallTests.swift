//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// In an extension of a type its file does not declare, `Self.init(x)` is held and counted beside every initializer's list as `Self(x)` is, said with an implicit `.init call` in one count where both are found; a `self.init(x)` delegating there is listed only under the type extended, never counted for another.
@Suite(.temporaryDirectories)
struct SyntacticCallerUntoldSelfCallTests {
    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Box {
                init(size: Int) {}
            }

            struct Lid {
                init(size: Int) {}
            }

            protocol Maker {
                init(size: Int)
            }
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.write("extension Maker {\n    static func again() -> Self { Self.init(size: 2) }\n}\n", to: "Sources/App/Maker.swift", in: root)
        try TestSources.write("extension Lid {\n    init(other: Int) { self.init(size: other) }\n}\n", to: "Sources/App/Lid.swift", in: root)
        try TestSources.write("func build() {\n    consume(\(WhereInitializerCallsTests.implied)(size: 1))\n}\n", to: "Sources/App/Build.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aSelfInitInAnUntoldExtensionIsHeldAndCountedWithAnImplicitInitInOneCount() async throws {
        let root = try Self.repo()

        let output = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(output.contains("but an implicit .init or Self(…) in an extension is called 2 times with those labels on a type the scan cannot tell, any of which may be Box's"), "\(output)")
        #expect(rows.contains("  Sources/App/Maker.swift:2  in Maker.again()"), "\(output)")
        #expect(rows.contains("  Sources/App/Build.swift:2  in build()"), "\(output)")
    }

    @Test
    func aSelfDotInitInAnExtensionOfAnUndeclaredTypeIsLeftOutOfOtherTypesCountsAndListedUnderItsOwn() async throws {
        let root = try Self.repo()

        let box = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let lid = try await WhereInitializerCallsTests.lookup("Lid.init(size:)", in: root)

        #expect(!box.contains("in Lid.init(other:)"), "\(box)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(lid).contains("  Sources/App/Lid.swift:2  in Lid.init(other:)"), "\(lid)")
    }
}
