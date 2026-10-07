//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `where <typealias>`'s own usage verdict.
///
/// `where <Type>` carries a "used by" line so a deletion unit never reads an empty caller list as "nothing uses this"; asking about the alias itself must not fall back to the plain-references view, which is that same misreading on the alias's own name.
@Suite(.temporaryDirectories)
struct TypealiasUsageWhereTests {
    /// The same fixture `TypeUsageWhereTests` builds for the type's own fold test: `Gizmo`, `Crate = Gizmo`, `Box = Crate`, and three tests reaching `Gizmo` only through the two aliases.
    private static func makeAliasRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                    .testTarget(name: "LibTests", dependencies: ["Lib"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}

                public static func go() -> Int { 1 }
            }

            public typealias Crate = Gizmo
            public typealias Box = Crate
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.write(
            """
            import XCTest
            @testable import Lib

            final class Crates: XCTestCase {
                func testOne() {
                    XCTAssertEqual(Crate.go(), 1)
                }

                func testTwo() {
                    _ = Crate()
                }

                func testThree() {
                    let made: Box = Box()
                    _ = made
                }
            }
            """,
            to: "Tests/LibTests/Crates.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "alias fixture")
        try TestSources.swiftBuild(packageAt: root, includingTests: true)
        return root
    }

    /// `where <typealias>` gets a usage verdict of its own, in the type's vocabulary — and the alias-of-a-type fold it reuses, asked from the alias's own USR, works one hop sideways: `Box`, an alias *of* `Crate`, folds into `Crate`'s own verdict exactly the way `Crate` folds into `Gizmo`'s.
    @Test
    func aTypealiasQueryGetsItsOwnUsageVerdict() async throws {
        let root = try Self.makeAliasRepo()
        let engine = try SiftEngine(directory: root)
        // The fixture is built with its tests, so its store is big enough to still be opening under full-suite load.
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Crate", freshness: freshness)

        // Crate.go() and Crate() are its own; Box() is Crate's own alias, folded in the same way Crate folds into
        // Gizmo's verdict — all three land in the one test file, none in production.
        #expect(output.contains("used by Lib.Crate: 3 references in 1 file — 0 production · 3 tests"))
        #expect(output.contains("1 written as Lib.Box, a typealias naming it — recorded against the alias, folded in here"))
        #expect(output.contains("1 more line declaring a typealias of it, which is another name for the type rather than use of it"))
        // The clause names the fold as well as the alias: two of the three lines spell `Crate`, the third spells
        // `Box`, and "counts its own name" alone would leave a reader who greps `Crate` one line short of the number.
        #expect(output.contains("counts Lib.Crate's own name, and any typealias of it, not the type it names — that type may still be used directly, under its own name, without this alias"))
        #expect(output.contains("Tests/LibTests/Crates.swift (3): — 1 written as Lib.Box\n    :6  | XCTAssertEqual(Crate.go(), 1)\n    :10  | _ = Crate()\n    :14  | let made: Box = Box()"))
    }

    /// A fixture where the underlying type is used under its own name, apart from any of its aliases, and one of its aliases is never spelled anywhere — the shape `where <alias>` must answer honestly: a reader must not mistake `Gizmo`'s own use for `Nickname` being in use.
    private static func makeUnusedAliasRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}
            }

            public typealias Nickname = Gizmo
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.write(
            """
            public func makeGizmo() -> Gizmo {
                Gizmo()
            }
            """,
            to: "Sources/Lib/Assembly.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "unused alias fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// The type an unused alias names can be used directly and often is — that is not the alias being in use, and the verdict says so rather than leaving the reader to notice `Gizmo` was never asked about.
    @Test
    func anUnusedAliasDoesNotBorrowItsTypesUsage() async throws {
        let root = try Self.makeUnusedAliasRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Nickname", freshness: freshness)

        #expect(output.contains(
            "no references to Lib.Nickname recorded in the store — counts the alias's own name, and any typealias of it, not the type it names, which may still be used directly, under its own name, without it; check comments and strings with grep"
        ))
        // The reading this must not permit: nothing here says or implies Nickname itself is used.
        #expect(!output.contains("used by Lib.Nickname"))
    }

    /// One finding, said once.
    ///
    /// The alias's emptiness is stated by its own usage line, in the vocabulary a deletion is decided in; the sweep view saying it again in plainer words reads as a second, weaker finding about the same name.
    @Test
    func anUnusedAliasSaysItsEmptinessOnceUnderRefs() async throws {
        let root = try Self.makeUnusedAliasRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let swept = try await engine.lookup(symbol: "Nickname", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(swept.components(separatedBy: "no references to Lib.Nickname recorded in the store").count == 2)
        // The one sentence that survives is the alias's own, which says which name it counted.
        #expect(swept.contains("counts the alias's own name, and any typealias of it, not the type it names"))
    }

    /// A fixture for the two shapes a type's "its own declaration and extensions are not use" rule can take from an alias: a use written on the declaration's own line, and an `extension` written over the alias's name.
    ///
    /// Neither is the alias naming itself — a definition is not a reference, so an alias's declaration records nothing of its own to take out — and both stop compiling when the alias goes.
    private static func makeAliasOwnLineRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}
            }

            public typealias Crate = Gizmo

            extension Crate {
                public func label() -> Int { 1 }
            }

            public typealias Box = Gizmo; public func makeGizmo(_ box: Box) -> Box { box }
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "own-line alias fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// A line that spells the alias is a use of it whatever else that line does, and an alias has no lines of its own to discount: the type's rule, reused, denied an alias two other files still needed.
    @Test
    func anAliasIsUsedByTheLinesItsOwnRuleWouldHaveDiscounted() async throws {
        let root = try Self.makeAliasOwnLineRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let extended = try await engine.lookup(symbol: "Crate", freshness: freshness)
        let sameLine = try await engine.lookup(symbol: "Box", freshness: freshness)

        // `extension Crate` dies with the type it would be written over; it does not die with the alias, which the
        // header has to stop naming before the alias can go.
        #expect(extended.contains("used by Lib.Crate: 1 reference in 1 file — 1 production · 0 tests"), "\(extended)")
        #expect(!extended.contains("no uses of Lib.Crate"), "\(extended)")
        // `makeGizmo` takes and returns the alias, and happens to be written on the declaration's own line.
        #expect(sameLine.contains("used by Lib.Box: 1 reference in 1 file — 1 production · 0 tests"), "\(sameLine)")
        #expect(!sameLine.contains("no uses of Lib.Box"), "\(sameLine)")
    }

    /// A fixture where an alias is named by nothing but an alias of its own, and that one is never spelled anywhere.
    private static func makeAliasOfAnAliasRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}
            }

            public typealias Nickname = Gizmo
            public typealias Box = Nickname
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "alias of an alias fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// An alias whose every reference is another alias declaring itself over it gets that finding in its own words — and under `--refs` it points at the lines it is disowning, which the sweep has already listed above it.
    @Test
    func anAliasOnlyItsOwnAliasesNameSaysSoAndOwnsTheLines() async throws {
        let root = try Self.makeAliasOfAnAliasRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let swept = try await engine.lookup(symbol: "Nickname", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(swept.contains(
            "no uses of Lib.Nickname recorded in the store — every reference recorded is another typealias naming it, which is another name for it rather than use of it, and nothing uses those either, so they go with it — the references listed above are those lines — counts the alias's own name, and any typealias of it, not the type it names, which may still be used directly, under its own name, without it; check comments and strings with grep"
        ), "\(swept)")
        // The one explanation it can never be: an alias's own declaration is a definition, and definitions are
        // not references, so nothing it says about itself is ever in the count this sentence is denying.
        #expect(!swept.contains("the alias declaring itself"), "\(swept)")
        let lines = swept.split(separator: "\n", omittingEmptySubsequences: false)
        let listing = try #require(lines.firstIndex(where: { $0.hasSuffix("  Sources/Lib/Gizmo.swift (1):") }), "\(swept)")
        #expect(lines[listing + 1].hasPrefix("    :6  | "), "\(swept)")
        let sentence = try #require(lines.firstIndex(where: { $0.contains("the references listed above are those lines") }), "\(swept)")
        #expect(listing < sentence, "\(swept)")
    }

    /// A fixture with one more alias than the fold follows, the last of them sharing a line with two it does follow — the shape that reaches ``WhereRenderer/typealiasFoldCap`` and still leaves every reference accounted for by an alias declaration.
    ///
    /// `Box1` names `Gizmo`; every other alias names `Box1`, so the type's fold and the alias's own both run out of budget here, one round apart.
    private static func makeCappedFoldRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [
                    .target(name: "Lib"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        let cap = WhereRenderer.typealiasFoldCap
        let ownLines = (2 ..< cap).map { "public typealias Box\($0) = Box1" }
        let shared = (cap ... cap + 2).map { "public typealias Box\($0) = Box1" }.joined(separator: "; ")
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}
            }

            public typealias Box1 = Gizmo
            \(ownLines.joined(separator: "\n"))
            \(shared)
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "capped fold fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// "Nothing uses those either, so they go with it" is a claim about aliases the fold read, and at its cap there are aliases it did not read — any one of which can be the use that stops the deletion.
    ///
    /// Both verdicts that make the claim, the type's and the alias's, say which of the two they are making.
    @Test
    func aFoldThatStoppedAtItsCapDoesNotPromiseTheAliasesGoToo() async throws {
        let root = try Self.makeCappedFoldRepo()
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let alias = try await engine.lookup(symbol: "Box1", freshness: freshness)
        let type = try await engine.lookup(symbol: "Gizmo", freshness: freshness)
        let stopped = "and nothing uses the ones this followed either, though the fold stopped at \(WhereRenderer.typealiasFoldCap) typealiases, so an alias past that may still be used"

        #expect(alias.contains("no uses of Lib.Box1 recorded in the store — every reference recorded is another typealias naming it, which is another name for it rather than use of it, \(stopped)"), "\(alias)")
        #expect(type.contains("no uses of Lib.Gizmo recorded in the store — every reference recorded is the type declaring itself or a typealias declaration naming it, which is another name for the type rather than use of it, \(stopped)"), "\(type)")
        #expect(!alias.contains("so they go with it"), "\(alias)")
        #expect(!type.contains("so they go with it"), "\(type)")
    }

    /// `where <alias>` with no index store at all — never built, so there is nothing `isAskedOfTheStore` could ask.
    ///
    /// Every other fixture in this suite builds first; this one pins what a typealias query answers before that ever happens.
    @Test
    func aTypealiasQueryWithNoStoreGetsTheSyntacticStandIn() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public struct Gizmo {}

            public typealias Crate = Gizmo
            """,
            to: "Sources/Lib/Gizmo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "alias fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Crate", freshness: freshness)

        #expect(output.contains("callers/overrides: NOT ANSWERED"), "\(output)")
        #expect(output.contains("no use spelled \"Crate\" anywhere — no construction, no member reached through it, and no annotation"), "\(output)")
    }
}
