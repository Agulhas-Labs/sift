//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `where` with no store over typealiases declared inside a function, which the index holds no row of.
@Suite(.temporaryDirectories)
struct WhereLocalTypealiasFoldTests {
    /// `Sources/App/Net.swift`, whose module is guessed as `Sources` where no `Package.swift` says otherwise.
    private static var netFile: String {
        """
        enum Net {
            struct URL {
                init() {}
            }
        }

        """
    }

    /// The `--refs` answer for `Net.URL` over a tree holding `Net.swift` and `Sources/App/Local.swift` holding `local`, with no `Package.swift`.
    private static func references(local: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.netFile, to: "Sources/App/Net.swift", in: root)
        try TestSources.write(local, to: "Sources/App/Local.swift", in: root)
        try TestSources.commitAll(in: root, message: "local alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: "Net.URL", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A local alias writing the whole path is folded in, and one writing it behind a leading name that may be the guessed module is kept and says why.
    @Test
    func usesOfALocalAliasAreFoldedOrKept() async throws {
        let output = try await Self.references(local: """
        func g() {
            typealias Loc = App.Net.URL
            _ = Loc()
        }
        func h() {
            typealias Loc2 = Net.URL
            _ = Loc2()
        }
        """)

        #expect(output.contains("\n    :3  | _ = Loc()\n"), "\(output)")
        #expect(output.contains("\n    :7  | _ = Loc2()"), "\(output)")
        #expect(output.contains("1 written as Sources.h().Loc2, a typealias naming it, folded in here"), "\(output)")
        #expect(output.contains(
            "1 written as Sources.g().Loc (App.Net.URL), a typealias of its path behind a leading name that may be its module, kept as a use though not proven to name it, as this type's module is guessed from the path"
        ), "\(output)")
    }

    /// A local alias's name means it only in the block declaring it, so another function's alias of the name for another type keeps its uses out.
    @Test
    func aLocalAliasIsFollowedOnlyInItsOwnBlock() async throws {
        let output = try await Self.references(local: """
        func g() {
            typealias Loc = Net.URL
            _ = Loc()
        }

        func h() {
            typealias Loc = Gizmo
            _ = Loc()
        }
        """)

        #expect(output.contains("\n    :3  | _ = Loc()"), "\(output)")
        #expect(!output.contains(":8  | _ = Loc()"), "\(output)")
        #expect(output.contains("1 written as Sources.g().Loc, a typealias naming it, folded in here"), "\(output)")
    }

    /// A block nearer the use declaring another type of the alias's name hides the alias there, but one doing so only inside an `#if` clause may be compiled out and hides nothing.
    @Test
    func aNearerDeclarationOfTheNameHidesALocalAlias() async throws {
        let output = try await Self.references(local: """
        func g() {
            typealias Loc = Net.URL
            func inner() {
                typealias Loc = Int
                _ = Loc()
            }
            func outer() {
                #if DEBUG
                struct Loc {}
                #endif
                _ = Loc()
            }
            _ = Loc()
        }
        """)

        #expect(!output.contains(":5  | _ = Loc()"), "\(output)")
        #expect(output.contains("\n    :11  | _ = Loc()\n"), "\(output)")
        #expect(output.contains("\n    :13  | _ = Loc()"), "\(output)")
        #expect(output.contains("2 written as Sources.g().Loc, a typealias naming it, folded in here"), "\(output)")
    }

    /// A local alias whose right-hand side writes the name bare inside a type declaring its own type of the name names that type, so its uses are not folded in.
    @Test
    func aLocalAliasOfAnotherTypeOfTheNameIsNotFollowed() async throws {
        let output = try await Self.references(local: """
        struct Holder {
            struct URL {}
            func g() {
                typealias Loc = URL
                _ = Loc()
            }
        }
        """)

        #expect(!output.contains(":5  | _ = Loc()"), "\(output)")
        #expect(!output.contains("Sources.Holder.g().Loc"), "\(output)")
        #expect(output.contains("1 more line writing \"URL\" bare inside a type that declares its own \"URL\""), "\(output)")
    }
}
