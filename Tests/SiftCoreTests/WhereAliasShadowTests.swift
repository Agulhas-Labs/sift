//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a type's name-matched uses written through a typealias whose name a nearer scope declares its own of, with no index store.
///
/// A use is folded in only through an alias it can resolve to: `Crate("t")` inside an `enum Space` that declares its own `typealias Crate = Other` names `Other`, not the top-level `typealias Crate = Gizmo`, so it is counted apart with the rule said. Where the scope cannot tell, the use is kept, worded unproven.
@Suite(.temporaryDirectories)
struct WhereAliasShadowTests {
    private static var base: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        struct Other {
            init(_ name: String) {}
        }
        typealias Crate = Gizmo
        """
    }

    private static var space: String {
        """
        enum Space {
            typealias Crate = Other
        }
        """
    }

    private static var folded: String {
        "1 written as Sources.Crate, a typealias naming it, folded in here"
    }

    private static var kept: String {
        "1 written as Sources.Crate, a typealias naming it whose name another declaration shares, kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static func lookup(_ symbol: String = "Gizmo", declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// Whether `output` holds `clause` whole, as one of the clauses a count line opens with " — ", joins with "; " or closes with " (for".
    private static func holdsClause(_ clause: String, in output: String) -> Bool {
        ["; " + clause + ";", "; " + clause + " (for", " — " + clause + ";", " — " + clause + " (for"].contains { output.contains($0) }
    }

    /// A use inside a type that declares its own alias of the name is counted apart, and one in a type that does not is still folded in.
    @Test
    func aUseInsideATypeDeclaringItsOwnAliasIsCountedApart() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            extension Space {
                static func make() -> Other { Crate("t") }
            }
            struct Shop {
                func make() { _ = Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause("1 more line writing \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, so not use", in: output), "\(output)")
        #expect(Self.holdsClause(Self.folded, in: output), "\(output)")
        #expect(!output.contains("Sources/App/Calls.swift (2)"), "\(output)")
        #expect(!output.contains(":2  |"), "\(output)")
    }

    /// A use inside a type with a supertype outside the index is kept, never folded in: that supertype may declare its own of the name.
    @Test
    func aUseBelowASupertypeOutsideTheIndexIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            import Foundation

            class Panel: NSObject {
                func make() { _ = Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// A use behind a qualifier is kept, never folded in, where another declaration shares the alias's name.
    @Test
    func aQualifiedUseIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            struct Shop {
                func make() -> Other { Space.Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// A use inside a function that declares its own type of the name is counted apart.
    @Test
    func aUseInsideAFunctionDeclaringItsOwnTypeIsCountedApart() async throws {
        let output = try await Self.lookup(
            declaring: Self.base,
            calling: """
            struct Shop {
                func make() {
                    struct Crate {
                        init(_ s: String) {}
                    }
                    _ = Crate("t")
                }
            }
            """
        )

        #expect(Self.holdsClause("1 more line writing \"Crate\" bare inside a function that declares its own \"Crate\", which is what the name means there, so not use", in: output), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// A use inside a function that declares its own typealias of the name is kept, never folded in: the index holds no row of it to say what it names.
    @Test
    func aUseInsideAFunctionDeclaringItsOwnTypealiasIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.base,
            calling: """
            struct Shop {
                func make() -> Other {
                    typealias Crate = Other
                    return Crate("t")
                }
            }
            """
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// A function-local typealias whose right-hand side writes the alias's name where a type around it declares its own is not followed as another name for the type.
    @Test
    func aLocalTypealiasOfAShadowedAliasIsNotFollowed() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            extension Space {
                static func make() -> Other {
                    typealias Bin = Crate
                    return Bin("t")
                }
            }
            """
        )

        #expect(!output.contains("Bin"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// With no other declaration of the alias's name, a use through it is folded in, as it always was.
    @Test
    func aUseThroughAnUnsharedAliasIsFoldedIn() async throws {
        let output = try await Self.lookup(
            declaring: Self.base,
            calling: """
            struct Shop {
                func make() { _ = Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause(Self.folded, in: output), "\(output)")
    }
}
