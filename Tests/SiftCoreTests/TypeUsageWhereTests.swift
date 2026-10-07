//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the default `where <Type>` usage section against a really built index store.
///
/// A type is neither called nor read, so leaving its references behind `--refs` left the default answer with no section and no empty case — and silence was read as "nothing uses this".
@Suite(.temporaryDirectories, .serialized)
struct TypeUsageWhereTests {
    /// A built fixture for the default type-usage section: a type used from production and from a test, an extension of it that spells its name three times over, a type used only by a sibling in its own declaring file, a type only its own extension names, and a type nothing touches at all.
    private static func usageFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "usage") { root in
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
                public struct Widget {
                    public init() {}
                }

                public extension Widget {
                    func spin() -> Widget {
                        Widget()
                    }
                }

                public struct Forgotten {
                    public init() {}
                }
                """,
                to: "Sources/Lib/Widget.swift",
                in: root
            )
            try TestSources.write(
                """
                public func assemble() -> Widget {
                    Widget()
                }
                """,
                to: "Sources/Lib/Assembly.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Host {
                    public init() {}
                }

                public struct Console {
                    public init() {}

                    public func boot() -> Host {
                        Host()
                    }
                }
                """,
                to: "Sources/Lib/Host.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Lonely {
                    public init() {}
                }

                public extension Lonely {
                    func twin() -> Lonely {
                        Lonely()
                    }
                }
                """,
                to: "Sources/Lib/Lonely.swift",
                in: root
            )
            try TestSources.write(
                """
                import XCTest
                @testable import Lib

                final class WidgetTests: XCTestCase {
                    func testExample() {
                        _ = Widget().spin()
                    }
                }
                """,
                to: "Tests/LibTests/WidgetTests.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "usage fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
    }

    /// A type has no callers, so leaving its usage behind `--refs` left the default answer silent about the one thing a deletion turns on — and silence was read as "nothing uses this".
    @Test
    func aTypesUsageIsNamedWithoutAskingForRefs() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Widget", freshness: freshness)

            #expect(output.contains("used by Lib.Widget: 3 references in 2 files — 2 production · 1 test"))
            #expect(output.contains("Sources/Lib/Assembly.swift (2):\n    :1  | public func assemble() -> Widget {\n    :2  | Widget()"))
            #expect(output.contains("Tests/LibTests/WidgetTests.swift (1):\n    :6  | _ = Widget().spin()"))
            // The deletion verdict is exactly where the two reference boundaries matter, so the default section carries them.
            #expect(output.contains("references: code only (not comments or strings) and this repo's own build only"))
        }
    }

    /// The usage section has no cursor of its own — its truncation marker points at `--refs` — so an `--offset` sent without `--refs` must not be silently dropped: it is served anyway, named as unused, the same as digest's single-page neighbours block.
    @Test
    func anOffsetWithoutRefsIsNamedAsUnusedRatherThanIgnored() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(
                symbol: "Widget",
                freshness: freshness,
                options: WhereOptions(offset: 3)
            )

            #expect(output.contains("used by Lib.Widget: 3 references in 2 files"))
            #expect(output.contains("(offset 3 unused — this section pages under --refs, not here)"))
        }
    }

    /// The type's own extension is the type declaring itself; counting its header would make every type with an extension look used.
    @Test
    func aTypesOwnExtensionIsNotCountedAsUsage() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Widget", freshness: freshness)

            // Widget.swift spells the name on the extension header, the return type and the construction inside it.
            #expect(!output.contains("  Sources/Lib/Widget.swift ("))
            // Dropped in the open, never in silence: a count that quietly excluded sites is the defect this section ends.
            #expect(output.contains("3 more lines inside its own declaration or its extensions in this module, which is not use"))
        }
    }

    /// The empty case is a sentence, never an absent section — the whole defect was that a type with no section read as a type with no users.
    @Test
    func aTypeNothingUsesSaysSoRatherThanSayingNothing() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let plain = try await engine.lookup(symbol: "Forgotten", freshness: freshness)
            let swept = try await engine.lookup(symbol: "Forgotten", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(plain.contains("no references to Lib.Forgotten recorded in the store — check comments and strings with grep"))
            #expect(!plain.contains("used by Lib.Forgotten"))
            // One finding, said once: the sweep view must not repeat the emptiness the usage line already stated.
            #expect(swept.components(separatedBy: "no references to Lib.Forgotten recorded in the store").count == 2)
        }
    }

    /// A sibling reaching for a type from the same file is a real dependency — one that breaks when the type goes — so only the type's *own* declaration and extensions come out, never the file they are written in.
    @Test
    func aSiblingInTheDeclaringFileIsCountedAsUsage() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Host", freshness: freshness)

            // `Console.boot()` names `Host` on its return type and in its body, both in `Host`'s own file.
            #expect(output.contains("used by Lib.Host: 2 references in 1 file — 2 production · 0 tests"))
            #expect(output.contains("Sources/Lib/Host.swift (2):\n    :8  | public func boot() -> Host {\n    :9  | Host()"))
            #expect(!output.contains("no uses of Lib.Host"))
        }
    }

    /// "Nothing references it" and "every reference is the type spelling its own name" are different findings, and the second one is the sentence a false claim would be made in — so it is rendered, and says where its lines are when the sweep is listing them.
    @Test
    func aTypeOnlyItsOwnExtensionNamesSaysThatRatherThanNothing() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let plain = try await engine.lookup(symbol: "Lonely", freshness: freshness)
            let swept = try await engine.lookup(symbol: "Lonely", freshness: freshness, options: WhereOptions(includeReferences: true))

            // `Lonely` is named on its extension's header, its return type and its construction, and nowhere else.
            #expect(plain.contains("no uses of Lib.Lonely recorded in the store — every reference recorded falls inside its own declaration or its extensions in this module, which is the type spelling its own name; check comments and strings with grep"))
            #expect(!plain.contains("no references to Lib.Lonely"))
            // The sweep lists those very lines, so the verdict must own them rather than read as denying a list elsewhere.
            #expect(swept.contains("which is the type spelling its own name — the references listed above are those lines"))
            // Pinned by position, not by wording alone: a substring check cannot see that the sections are appended
            // before every summary line, which is how "below" survived a green suite while pointing at the extensions
            // block instead of the listing the sentence owns.
            let lines = swept.split(separator: "\n", omittingEmptySubsequences: false)
            let listing = try #require(lines.firstIndex(where: { $0.hasSuffix("  Sources/Lib/Lonely.swift (3):") }), "\(swept)")
            #expect(lines[(listing + 1) ... (listing + 3)].map { String($0.prefix { $0 != "|" }) } == ["    :5  ", "    :6  ", "    :7  "], "\(swept)")
            let sentence = try #require(lines.firstIndex(where: { $0.contains("the references listed above are those lines") }), "\(swept)")
            #expect(listing < sentence, "\(swept)")
        }
    }

    @Test
    func usageCountsReconcileWithTheLinesListed() async throws {
        try await Self.usageFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Widget", freshness: freshness)

            // A verdict promising more sites than the listing accounts for is a deletion made on a number nothing backs.
            let opening = "used by Lib.Widget: "
            let verdict = try #require(output.split(separator: "\n").first(where: { $0.hasPrefix(opening) }), "\(output)")
            let total = Int(verdict.dropFirst(opening.count).prefix(while: { $0 != " " })) ?? -1
            // Few enough to be listed one row per line with its text, so each row is one site.
            let listed = output
                .split(separator: "\n")
                .drop { !$0.hasPrefix(opening) }
                .dropFirst()
                .prefix { $0.hasPrefix("  ") }
                .count { $0.hasPrefix("    :") }

            #expect(total == listed)
        }
    }

    /// A fixture for a type nothing spells by name: `Gizmo` is used only through `Crate`, an alias of it, and through `Box`, an alias of that — three XCTest methods in all, and not one of them writes `Gizmo`.
    private static func aliasFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "alias") { root in
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
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
    }

    /// A use written through a typealias is recorded against the alias, so a verdict counting only the type's own USR said `0 tests` about a type three tests break on — this section's own defect wearing a number.
    @Test
    func aUseWrittenThroughATypealiasIsCountedAsUsage() async throws {
        try await Self.aliasFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Gizmo", freshness: freshness)

            // The three test methods reach it through the two aliases; the alias declarations themselves are another name
            // for the type rather than use of it, so they are counted apart and never as production use.
            #expect(output.contains("used by Lib.Gizmo: 3 references in 1 file — 0 production · 3 tests"))
            #expect(output.contains("2 more lines declaring a typealias of it, which is another name for the type rather than use of it"))
            // The line a deletion is decided on, which the fold exists to stop being false.
            #expect(!output.contains("· 0 tests"))
            // A fold that cannot be read is a number that is merely larger, so the row names what is written at the site.
            #expect(output.contains("Tests/LibTests/Crates.swift (3): — written as Lib.Box and Lib.Crate\n    :6  | XCTAssertEqual(Crate.go(), 1)\n    :10  | _ = Crate()\n    :14  | let made: Box = Box()"))
            #expect(output.contains("written as Lib.Box and Lib.Crate, typealiases naming it — recorded against the alias, folded in here"))
        }
    }

    /// An alias of an alias is followed to a fixed point: one level sees only `Crate`'s own declaration, so the test using `Box` would be missed by exactly the reasoning that missed the ones using `Crate`.
    @Test
    func anAliasOfAnAliasIsFollowedToTheUseSite() async throws {
        try await Self.aliasFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let output = try await engine.lookup(symbol: "Gizmo", freshness: freshness)

            // Line 14 is `let made: Box = Box()`, reachable only through the second alias.
            let lines = output.split(separator: "\n")
            let heading = try #require(lines.firstIndex(where: { $0.contains("Tests/LibTests/Crates.swift") }), "\(output)")

            #expect(lines[heading].contains("Lib.Box"), "\(output)")
            #expect(lines[(heading + 1)...].prefix { $0.hasPrefix("    :") }.contains("    :14  | let made: Box = Box()"), "\(output)")
        }
    }
}
