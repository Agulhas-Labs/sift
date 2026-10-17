//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how a typealias's name written in a body or below a supertype outside the index is read, with no index store.
///
/// A body's own declaration of the name is told from a row the index holds by where it starts, not by its line, so an attribute above a member alias or a body sharing a top-level alias's line reads as Swift's lookup does. Past a supertype outside the index, a nested alias writing the name reaches the nearest level declaring it where every declaration of the name is one of the type's aliases, as the name's only declaration is.
@Suite(.temporaryDirectories)
struct WhereAliasScopeLowsTests {
    private static var types: String {
        """
        import AppKit

        struct Gizmo {
            init(_ name: String) {}
        }
        struct Other {
            init(_ name: String) {}
        }
        """
    }

    private static var kept: String {
        "1 written as Sources.Crate, a typealias naming it whose name another declaration shares, kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static var countedApart: String {
        "1 more line writing \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, so not use"
    }

    private static func lookup(declaring declarations: String, calling calls: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Gizmo", freshness: freshness)
        #expect(!output.contains("parse errors"), "\(output)", sourceLocation: sourceLocation)
        return output
    }

    /// Whether `output` holds `clause` whole, as one of the clauses a count line opens with " — ", joins with "; " or closes with " (for".
    private static func holdsClause(_ clause: String, in output: String) -> Bool {
        ["; " + clause + ";", "; " + clause + " (for", " — " + clause + ";", " — " + clause + " (for"].contains { output.contains($0) }
    }

    /// A member alias with an attribute on the line above starts where its row does, so a use in a method of its type is counted apart as the other declaration it means.
    @Test
    func aUseBelowAnAttributedMemberAliasIsCountedApart() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                @available(*, deprecated)
                typealias Crate = Other
                static func make() -> Other { Crate("t") }
            }
            """,
            calling: """
            struct Shop {
                func make() { _ = Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause("1 more line writing \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, so not use", in: output), "\(output)")
        #expect(!output.contains("not proven"), "\(output)")
    }

    /// A body's own alias on the line a top-level alias of the name starts on is not that alias: the name there means the body's, so the use is never folded in.
    @Test
    func aBodyAliasSharingATopLevelAliasLineIsNotFoldedIn() async throws {
        let output = try await Self.lookup(
            declaring: Self.types,
            calling: """
            typealias Crate = Gizmo; func one() { typealias Crate = Other; _ = Crate("x") }
            """
        )

        #expect(!output.contains("folded in here"), "\(output)")
        #expect(output.contains("not proven"), "\(output)")
    }

    /// A nested alias below a supertype outside the index, writing a name two aliases of the type declare, is folded in: the nearest level declaring the name holds only aliases of it.
    @Test
    func aNestedAliasPastAnUnseenSupertypeToTwoAliasesIsFolded() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                typealias Crate = Gizmo
            }
            class Panel: NSObject {
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Panel {
                func f() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains("1 written as Sources.Panel.Bin, a typealias naming it, folded in here"), "\(output)")
        #expect(!output.contains("not proven"), "\(output)")
    }

    /// A nested alias writing a name its superclass declares an alias of the type by is folded in: the inherited declaration is the nearest, and one of the type's aliases.
    @Test
    func aNestedAliasReachingAnInheritedAliasIsFolded() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            class Base {
                typealias Crate = Gizmo
            }
            class Panel: Base {
                typealias Bin = Crate
            }
            """,
            calling: """
            extension Panel {
                func f() { _ = Bin("t") }
            }
            """
        )

        #expect(output.contains("1 written as Sources.Panel.Bin, a typealias naming it, folded in here"), "\(output)")
        #expect(!output.contains("not proven"), "\(output)")
    }

    /// A use below a supertype outside the index, where the nearest level declaring the name holds another type of it, is still kept: the supertype may declare its own nearer.
    @Test
    func aUsePastAnUnseenSupertypeToAnotherDeclarationIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                struct Crate {
                    init(_ name: String) {}
                }
            }
            """,
            calling: """
            extension Space {
                class Panel: NSObject {
                    func f() { _ = Crate("t") }
                }
            }
            """
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// An attributed member alias declared only inside an `#if` clause hides the top-level alias only in the builds compiling it, so a use in its type is kept.
    @Test
    func aUseBelowAnAttributedMemberAliasInsideAnIfClauseIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                #if DEBUG
                @available(*, deprecated)
                typealias Crate = Other
                #endif
                static func make() { _ = Crate("t") }
            }
            """,
            calling: "struct Shop {}"
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// A member alias declared only inside an `#if` clause leaves a use in its type kept.
    @Test
    func aUseBelowAMemberAliasInsideAnIfClauseIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                #if DEBUG
                typealias Crate = Other
                #endif
                static func make() { _ = Crate("t") }
            }
            """,
            calling: "struct Shop {}"
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// A use in an extension in another file, below a member alias declared only inside an `#if` clause, is kept.
    @Test
    func aUseInAnExtensionBelowAMemberAliasInsideAnIfClauseIsKept() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Space {
                #if DEBUG
                typealias Crate = Other
                #endif
            }
            """,
            calling: """
            extension Space {
                static func make() { _ = Crate("t") }
            }
            """
        )

        #expect(Self.holdsClause(Self.kept, in: output), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// A member alias declared in both clauses of an `#if`/`#else`, each naming another type, means another type in every build, so a use in its type is counted apart.
    @Test
    func aUseBelowMemberAliasesInEveryClauseIsCountedApart() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            struct Other2 {
                init(_ name: String) {}
            }
            typealias Crate = Gizmo
            enum Space {
                #if DEBUG
                typealias Crate = Other
                #else
                typealias Crate = Other2
                #endif
                static func make() { _ = Crate("t") }
            }
            """,
            calling: "struct Shop {}"
        )

        #expect(Self.holdsClause("1 more line writing \"Crate\" bare inside a type that declares its own \"Crate\", which is what the name means there, so not use", in: output), "\(output)")
        #expect(!output.contains("not proven"), "\(output)")
    }

    /// A type declared once per `#if` clause, one copy declaring its own `Crate`: a use in the copy declaring none means the top-level alias, so it is listed, while the declaring copy's use is counted apart.
    @Test
    func aUseInACopyOfATypeDeclaringNoAliasIsListed() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            #if DEBUG
            enum Space {
                typealias Crate = Other
                static func make() { _ = Crate("t") }
            }
            #else
            enum Space {
                static func make() { _ = Crate("t") }
            }
            #endif
            """,
            calling: "struct Shop {}"
        )

        #expect(output.contains(":17  | static func make() { _ = Crate(\"t\") }"), "\(output)")
        #expect(Self.holdsClause(Self.countedApart, in: output), "\(output)")
        #expect(!output.contains("2 more lines writing"), "\(output)")
    }

    /// The same one level down: a use in the copy of a nested type declaring no `Crate` is listed.
    @Test
    func aUseInACopyOfANestedTypeDeclaringNoAliasIsListed() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            enum Outer {
                #if DEBUG
                enum Space {
                    typealias Crate = Other
                    static func make() { _ = Crate("t") }
                }
                #else
                enum Space {
                    static func make() { _ = Crate("t") }
                }
                #endif
            }
            """,
            calling: "struct Shop {}"
        )

        #expect(output.contains(":18  | static func make() { _ = Crate(\"t\") }"), "\(output)")
        #expect(Self.holdsClause(Self.countedApart, in: output), "\(output)")
        #expect(!output.contains("2 more lines writing"), "\(output)")
    }

    /// The use in the copy declaring `Crate = Other` alone is counted apart, and nothing is left not proven.
    @Test
    func aUseInTheCopyDeclaringTheAliasIsCountedApart() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            #if DEBUG
            enum Space {
                typealias Crate = Other
                static func make() { _ = Crate("t") }
            }
            #else
            enum Space {
                static func run() {}
            }
            #endif
            """,
            calling: "struct Shop {}"
        )

        #expect(Self.holdsClause(Self.countedApart, in: output), "\(output)")
        #expect(!output.contains("not proven"), "\(output)")
    }

    /// A nested alias writing `Crate` in the copy of a type declaring no `Crate` names the type through the top-level alias, so a call through it is listed.
    @Test
    func aCallThroughANestedAliasInACopyDeclaringNoAliasIsListed() async throws {
        let output = try await Self.lookup(
            declaring: Self.types + "\n" + """
            typealias Crate = Gizmo
            #if DEBUG
            enum Space {
                typealias Crate = Other
                typealias Bin = Crate
            }
            #else
            enum Space {
                typealias Bin = Crate
            }
            #endif
            """,
            calling: "func f() { _ = Space.Bin(\"t\") }"
        )

        #expect(output.contains(":1  | func f() { _ = Space.Bin(\"t\") }"), "\(output)")
        #expect(Self.holdsClause(Self.countedApart, in: output), "\(output)")
    }
}
