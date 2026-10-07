//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A call written `Self(x)` or `Self.init(x)` inside a type or an extension of it calls that type's initializer, and a rename of the initializer's labels breaks it, so the name-matched sweep lists it under the innermost type around it.
///
/// In an extension of a type its file does not declare, `Self` may be any type conforming to a protocol, which the scan cannot tell: such a call is counted beside every initializer's list, never dropped.
@Suite(.temporaryDirectories)
struct SyntacticCallerSelfCallTests {
    static var box: String {
        """
        struct Box {
            init(size: Int) {}
            static func make() -> Box { Self(size: 1) }
            func again() -> Box { Self.init(size: 2) }
            func later() -> () -> Box { { Self(size: 3) } }
            struct Inner {
                init(size: Int) {}
                static func make() -> Inner { Self(size: 4) }
            }
        }

        extension Box {
            static func spare() -> Box { Self(size: 5) }
        }

        struct Lid {
            init(size: Int) {}
        }

        extension Lid {
            static func make() -> Lid { Self(size: 6) }
        }

        protocol Maker {
            init(size: Int)
        }
        """
    }

    /// A protocol extension in a file that spells neither an asked type nor an initializer's name, so only `Self(` gets it parsed.
    static var maker: String {
        """
        extension Maker {
            static func make() -> Self { Self(size: 7) }
        }
        """
    }

    static func repo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(box, to: "Sources/App/Box.swift", in: root)
        try TestSources.write(maker, to: "Sources/App/Maker.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aSelfCallInsideTheTypeIsACallOfItsInitializer() async throws {
        let root = try Self.repo()

        let output = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let rows = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(rows.contains("  Sources/App/Box.swift:3  in Box.make()"), "\(output)")
        #expect(rows.contains("  Sources/App/Box.swift:4  in Box.again()"), "\(output)")
        #expect(rows.contains("  Sources/App/Box.swift:5  in Box.later()"), "\(output)")
        #expect(!output.contains("no call spelled \"Box.init\""), "\(output)")
    }

    @Test
    func aSelfCallInAnExtensionIsTheExtendedTypesAndOneInANestedTypeIsTheInnermosts() async throws {
        let root = try Self.repo()

        let outer = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)
        let inner = try await WhereInitializerCallsTests.lookup("Box.Inner.init(size:)", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(outer).contains("  Sources/App/Box.swift:13  in Box.spare()"), "\(outer)")
        #expect(!outer.contains(":8  in Box.Inner.make()"), "\(outer)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(inner).contains("  Sources/App/Box.swift:8  in Box.Inner.make()"), "\(inner)")
        #expect(!inner.contains(":3  in Box.make()"), "\(inner)")
    }

    @Test
    func aSelfCallInAProtocolExtensionIsCountedBesideTheListAndAnotherDeclaredTypesIsNot() async throws {
        let root = try Self.repo()

        let output = try await WhereInitializerCallsTests.lookup("Box.init(size:)", in: root)

        #expect(output.contains("but Self(…) in an extension is called once with those labels on a type the scan cannot tell, any of which may be Box's"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(output)")
        #expect(!output.contains("in Lid.make()"), "\(output)")
    }

    /// Asked of the protocol's own initializer, the call is its: the index store records it as a call of the requirement.
    @Test
    func aSelfCallInAProtocolExtensionIsTheProtocolsWhereItsInitializerIsAsked() async throws {
        let root = try Self.repo()

        let output = try await WhereInitializerCallsTests.lookup("Maker.init(size:)", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Maker.swift:2  in Maker.make()"), "\(output)")
        #expect(!output.contains("on a type the scan cannot tell"), "\(output)")
    }

    /// A struct declaring no initializer is built through the memberwise one the compiler writes, which `Self(x)` calls as `Box(x)` does.
    @Test
    func aSelfCallReachesAMemberwiseInitializer() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Solo {
                var only: Int
                static func make() -> Solo { Self(only: 1) }
            }
            """,
            to: "Sources/App/Solo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await WhereInitializerCallsTests.lookup("Solo.init", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Solo.swift:3  in Solo.make()"), "\(output)")
        #expect(!output.contains("no call spelled \"Solo.init\""), "\(output)")
    }
}
