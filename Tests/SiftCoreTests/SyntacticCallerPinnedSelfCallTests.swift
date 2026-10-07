//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// In an extension whose where clause pins `Self` to a type, `extension Maker where Self == Lid`, a `Self(x)` calls that type's initializer: the sweep lists it under that type, declared in any file.
///
/// Its own file declaring neither `Lid` nor `Box`, either name may be an alias, so each pinned call is counted beside another type's list as one that may be theirs.
@Suite(.temporaryDirectories)
struct SyntacticCallerPinnedSelfCallTests {
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
        try TestSources.write(
            """
            extension Maker where Self == Lid {
                static func make() -> Self { Self(size: 1) }
                static func again() -> Self { Self.init(size: 2) }
            }

            extension Maker where Self: Equatable {
                static func spare() -> Self { Self(size: 3) }
            }

            extension Maker where Self == Box<Int> {
                static func boxed() -> Self { Self(size: 4) }
            }
            """,
            to: "Sources/App/Maker.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aSelfCallInAnExtensionPinningSelfIsThePinnedTypesAndMayBeAnothersWhereItsFileDeclaresNoneOfThem() async throws {
        let root = try Self.repo()

        let lid = try await WhereInitializerCallsTests.lookup("Lid.init(size:)", in: root)
        let box = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let lidRows = WhereAnswerRepetitionTests.sitesOnePerLine(lid)

        #expect(lidRows.contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(lid)")
        #expect(lidRows.contains("  Sources/App/Maker.swift:3  in Maker.again()"), "\(lid)")
        #expect(lid.contains("but Self(…) in an extension is called 2 times with those labels on a type the scan cannot tell, any of which may be Lid's"), "\(lid)")
        #expect(box.contains("\"Box.init\" (1 call site in 1 file):"), "\(box)")
        #expect(box.contains("but Self(…) in an extension is called 3 times with those labels on a type the scan cannot tell, any of which may be Box's"), "\(box)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(box).contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(box)")
    }

    @Test
    func aConformanceDoesNotPinSelfAndAGenericTypePinsItsName() async throws {
        let root = try Self.repo()

        let box = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)

        #expect(box.contains("but Self(…) in an extension is called 3 times with those labels on a type the scan cannot tell, any of which may be Box's"), "\(box)")
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(box)
        #expect(rows.contains("  Sources/App/Maker.swift:7  in Maker.spare()"), "\(box)")
        #expect(rows.contains("  Sources/App/Maker.swift:11  in Maker.boxed()"), "\(box)")
    }
}
