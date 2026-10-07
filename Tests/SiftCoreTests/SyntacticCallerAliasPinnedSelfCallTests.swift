//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A where clause pinning `Self` to a name the file declares as no struct, class, enum or actor, `extension Maker where Self == Cap` with `typealias Cap = Lid`, may pin it to an asked type under another name: the `Self(x)` in it is held and counted for every type asked, never lost.
@Suite(.temporaryDirectories)
struct SyntacticCallerAliasPinnedSelfCallTests {
    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Lid {
                init(size: Int) {}
            }

            struct Solo {
                var size: Int
            }

            typealias Cap = Lid
            typealias Top = Solo

            protocol Maker {
                init(size: Int)
            }
            """,
            to: "Sources/App/Lid.swift",
            in: root
        )
        try TestSources.write(
            """
            extension Maker where Self == Cap {
                static func make() -> Self { Self(size: 2) }
            }

            extension Maker where Self == Top {
                static func again() -> Self { Self(size: 3) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aSelfCallInAnExtensionPinningSelfToAnAliasIsCountedForTheTypeAsked() async throws {
        let root = try Self.repo()

        let lid = try await WhereInitializerCallsTests.lookup("Lid.init(size:)", in: root)

        #expect(lid.contains("but Self(…) in an extension is called 2 times with those labels on a type the scan cannot tell, any of which may be Lid's"), "\(lid)")
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(lid)
        #expect(rows.contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(lid)")
        #expect(rows.contains("  Sources/App/Maker.swift:6  in Maker.again()"), "\(lid)")
    }

    @Test
    func aSelfCallInAnExtensionPinningSelfToAnAliasIsListedWithAPropertysLabelUses() async throws {
        let root = try Self.repo()
        let engine = try SiftEngine(directory: root)

        let output = try await engine.lookup(symbol: "Solo.size", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(output.contains(":6  in Maker.again() (Self(…) on a type the scan cannot tell, which may be Solo)"), "\(output)")
    }

    /// A pin to a struct the same file declares names a type known to be no asked one, so its call is held for none.
    @Test
    func aSelfCallPinnedToAStructItsFileDeclaresIsHeldForNoOtherType() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Lid {\n    init(size: Int) {}\n}\n", to: "Sources/App/Lid.swift", in: root)
        try TestSources.write(
            """
            protocol Maker {
                init(size: Int)
            }

            struct Box: Maker {
                init(size: Int) {}
            }

            extension Maker where Self == Box {
                static func make() -> Self { Self(size: 2) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let lid = try await WhereInitializerCallsTests.lookup("Lid.init(size:)", in: root)

        #expect(!lid.contains("in Maker.make()"), "\(lid)")
    }
}
