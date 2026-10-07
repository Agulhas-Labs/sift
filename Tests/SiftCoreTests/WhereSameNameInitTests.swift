//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The name-matched sites of a declared initializer leave out the calls of another type that shares its type's simple name.
///
/// A site is found by the type's name, and one whose labels matched no declared initializer was kept as a call of one the compiler wrote, which credited the top-level `Inner(w: 2)` to `Outer.Inner` without a word and the static function call `Space.Gadget("x")` to `Gadget`.
@Suite(.temporaryDirectories)
struct WhereSameNameInitTests {
    static var shapes: String {
        """
        struct Inner { var w: Int }

        enum Outer {
            struct Inner { init(v: Int) {} }
            static func make() -> Int {
                _ = Inner(v: 1)
                return 0
            }
        }

        func buildTop() -> Int {
            _ = Inner(w: 2)
            return 0
        }

        struct Gadget { init(name: String) {} }

        enum Space {
            static func Gadget(_ text: String) -> Int { 0 }
        }

        func gadgets() -> Int {
            _ = Gadget(name: "a")
            return Space.Gadget("x")
        }
        """
    }

    static func lookup(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shapes, to: "Sources/App/Shapes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A call whose labels only another type of the name takes is kept for the nested type, which may have an init the scan cannot see, and flagged with the type they fit.
    @Test
    func aSameNamedTypesCallIsKeptFlaggedWithTheTypeItsLabelsFit() async throws {
        let output = try await Self.lookup("Outer.Inner.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(Self.rows(sites).contains("Sources/App/Shapes.swift:6  in Outer.make()"), "\(output)")
        #expect(sites.contains("Sources/App/Shapes.swift:12  in buildTop() (no declared init matches — compiler-written or inherited) (labels fit Sources.Inner)"), "\(output)")
        #expect(!output.contains("of another type named Inner dropped"), "\(output)")
    }

    /// A call qualified with a scope the index reads as declaring no type of the name is kept beside the type's own call, as reading a qualifier from the index alone is not sound.
    @Test
    func aCallQualifiedWithAnotherScopeIsKeptBesideTheTypes() async throws {
        let output = try await Self.lookup("Gadget.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Shapes.swift:23  in gadgets()"), "\(output)")
        #expect(sites.contains("Sources/App/Shapes.swift:24  in gadgets() (no declared init matches — compiler-written or inherited)"), "\(output)")
    }

    static var scopes: String {
        """
        struct Part { var w: Int }

        enum Rack {
            struct Part { init(v: Int) {} }
        }

        typealias Shelf = Rack
        typealias Bin = Remote

        func stock() -> Int {
            _ = Shelf.Part(v: 1)
            _ = Crate.Part(v: 2)
            _ = Bin.Part(v: 3)
            _ = Part(w: 4)
            return 0
        }

        class Base {
            struct Knob { var u: Int }
        }

        struct Knob { var t: Int }

        class Sub: Base {
            func turn() -> Int {
                _ = Knob(u: 1)
                return 0
            }
        }

        class Widget: Remote {
            func spin() -> Int {
                _ = Knob(t: 2)
                return 0
            }
        }

        func restock() -> Int { Sources.Part(w: 5) }
        """
    }

    static func lookupScopes(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(scopes, to: "Sources/App/Scopes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A call qualified with a typealias of the scope is the aliased scope's, and is credited to it without doubt.
    @Test
    func aCallQualifiedWithAnAliasIsTheAliasedScopes() async throws {
        let output = try await Self.lookupScopes("Rack.Part.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Scopes.swift:11  in stock()"), "\(output)")
        #expect(!sites.contains("Sources/App/Scopes.swift:11  in stock() (builds"), "\(output)")
    }

    /// A call qualified with a name the index cannot resolve, or with an alias of one, is kept and flagged rather than dropped, for the types its labels fit.
    @Test
    func aCallQualifiedWithAnUnresolvedNameIsKeptAmbiguous() async throws {
        let output = try await Self.lookupScopes("Rack.Part.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Scopes.swift:12  in stock() (builds Sources.Rack.Part only if Crate, which the index cannot resolve, names its scope)"), "\(output)")
        #expect(sites.contains("Sources/App/Scopes.swift:13  in stock() (builds Sources.Rack.Part only if Bin, through Remote, which the index cannot resolve, names its scope)"), "\(output)")
    }

    /// An unqualified call inside a subclass builds the nested type its superclass declares, and one whose labels only the top-level type takes is kept for it, flagged.
    @Test
    func aSubclassCallIsTheInheritedNestedTypes() async throws {
        let output = try await Self.lookupScopes("Base.Knob.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(Self.rows(sites).contains("Sources/App/Scopes.swift:26  in Sub.turn()"), "\(output)")
        #expect(Self.rows(sites).contains("Sources/App/Scopes.swift:33  in Widget.spin() (labels fit Sources.Knob)"), "\(output)")
    }

    /// An unqualified call inside a type whose superclass is outside the index is kept for the top-level type, and flagged in fifty characters.
    @Test
    func aCallInsideAnExternalSubclassIsKeptAmbiguous() async throws {
        let output = try await Self.lookupScopes("Knob.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Scopes.swift:33  in Widget.spin() (unless unindexed Remote declares its own Knob)"), "\(output)")
    }

    /// The name-scan fallback keeps a site whose qualifier the index reads as another same-named type's owner and notes it on the name's line, and keeps the one only its labels say is another's.
    @Test
    func theFallbackNotesTheSitesOfAnotherSameNamedType() async throws {
        let output = try await Self.lookupScopes("Rack.Part.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(output.contains("(5 call sites by name, 1 of them writes \"Part\" behind a qualifier the index reads as Sources, which declares another \"Part\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift, in 1 file"), "\(output)")
        #expect(sites.contains("Sources/App/Scopes.swift:14  in stock() (no declared init matches — compiler-written or inherited) (labels fit Sources.Part)"), "\(output)")
        #expect(sites.contains("Sources/App/Scopes.swift:38  in restock() (no declared init matches — compiler-written or inherited)"), "\(output)")
        #expect(!output.contains("of another type named Part dropped"), "\(output)")
    }

    /// A call of a static function spelled like the type is kept and noted as one the index reads as no call of its init, never dropped on that reading.
    @Test
    func aStaticFunctionSpelledLikeTheTypeIsNotedAsMaybeNoInitCall() async throws {
        let output = try await Self.lookup("Gadget.init")

        #expect(output.contains("(2 call sites by name, 1 of them writes \"Gadget\" behind a qualifier the index reads as Space, which declares no \"Gadget\", so may call no Gadget.init — counted all the same, as a qualifier read from the index alone may name another type in Swift, in 1 file):"), "\(output)")
        #expect(!output.contains("calling no Gadget.init dropped"), "\(output)")
        #expect(!output.contains("of another type named Gadget"), "\(output)")
    }

    /// Each site row of `sites`, its indent trimmed.
    static func rows(_ sites: String) -> [String] {
        sites.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static var shadows: String {
        """
        struct Inner { var w: Int }

        enum Outer {
            struct Inner { init(v: Int) {} }
        }

        func ctx() -> Outer.Inner { \(WhereInitializerCallsTests.implied)(v: 3) }

        let shadowed: Outer.Inner = \(WhereInitializerCallsTests.implied)(v: 4)

        enum Holder {
            typealias Inner = Outer.Inner
            static func h() -> Inner { Inner(v: 8) }
        }

        struct Cog { var w: Int }

        enum Gear {
            struct Cog { var w: Int }
        }

        enum Mount {
            typealias Cog = Gear.Cog
            static func m() -> Cog { Cog(w: 1) }
        }
        """
    }

    static func lookupShadows(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shadows, to: "Sources/App/Shadows.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// An implicit `.init call` whose declaration states a qualified type is that type's, whatever scope it is written in.
    @Test
    func anImplicitInitOfAQualifiedDeclaredTypeIsThatTypes() async throws {
        let output = try await Self.lookupShadows("Outer.Inner.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Shadows.swift:7  in ctx()"), "\(output)")
        #expect(sites.contains("Sources/App/Shadows.swift:9  "), "\(output)")
    }

    /// A call inside a type declaring a typealias of the name is kept for the type the alias names, never dropped for the top-level one.
    @Test
    func aCallThroughAnEnclosingTypealiasIsKept() async throws {
        let output = try await Self.lookupShadows("Outer.Inner.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(sites.contains("Sources/App/Shadows.swift:13  in Holder.h()"), "\(output)")
        #expect(!output.contains("of another type named Inner dropped"), "\(output)")
    }

    /// Where both types' labels fit, the enclosing typealias credits the call to the type it names, and the other type keeps it, flagged.
    @Test
    func anEnclosingTypealiasOnlyCreditsACall() async throws {
        let output = try await Self.lookupShadows("Cog.init")
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(Self.rows(sites).contains("Sources/App/Shadows.swift:24  in Mount.m()"), "\(output)")
        #expect(sites.contains("Sources/App/Shadows.swift:24  in Mount.m() (builds Sources.Cog or Sources.Gear.Cog — its scope names Sources.Gear.Cog)"), "\(output)")
    }
}

/// A fresh index store's reference on a site's line decides which same-named type it builds, over what the site writes.
extension WhereSameNameInitTests {
    /// Where only the scope tells the types apart, the store's record drops the call from the type it does not build.
    @Test
    func theStoresReferenceDropsACallTheScopeOnlyCredits() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [.target(name: "App")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Cog { var w: Int }

            enum Gear {
                struct Cog { var w: Int }
            }

            extension Gear {
                static func make() -> Int {
                    _ = Cog(w: 2)
                    return 0
                }
            }

            func top() -> Int {
                _ = Cog(w: 3)
                return 0
            }
            """,
            to: "Sources/App/Cogs.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Cog.init", freshness: freshness)
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(Self.rows(sites).contains("Sources/App/Cogs.swift:9  in Gear.make()"), "\(output)")
        #expect(!sites.contains("Sources/App/Cogs.swift:9  in Gear.make() (builds"), "\(output)")
        #expect(Self.rows(sites).contains("Sources/App/Cogs.swift:15  in top()"), "\(output)")
        #expect(!sites.contains("Sources/App/Cogs.swift:15  in top() (builds"), "\(output)")
    }
}
