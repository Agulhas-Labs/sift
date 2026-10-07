//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers whose extension the `where <Type>` usage verdict takes as the type's own, against a really built two-module index store.
@Suite(.temporaryDirectories)
struct CrossModuleTypeUsageWhereTests {
    /// A two-module fixture for the question "whose extension is this?": each target declares its own `Widget`, and `Beta`'s extension of *its* `Widget` uses `Alpha`'s inside the body — plus a nested `Outer.Item` whose extension uses the top-level `Item` of the same module, and a `Gizmo` extended once in its own module and once in `Beta`, which names it nowhere else.
    private static func makeCrossModuleRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Multi",
                targets: [
                    .target(name: "Alpha"),
                    .target(name: "Beta", dependencies: ["Alpha"]),
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
            """,
            to: "Sources/Alpha/Widget.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Item {
                public init() {}
            }
            """,
            to: "Sources/Alpha/Item.swift",
            in: root
        )
        try TestSources.write(
            """
            public enum Outer {
                public struct Item {
                    public init() {}
                }
            }

            public extension Outer.Item {
                func boxed() -> Alpha.Item {
                    Alpha.Item()
                }
            }
            """,
            to: "Sources/Alpha/Nested.swift",
            in: root
        )
        try TestSources.write(
            """
            import Alpha

            public struct Widget {
                public init() {}
            }

            public extension Widget {
                func make() -> Alpha.Widget {
                    Alpha.Widget()
                }
            }
            """,
            to: "Sources/Beta/Widget.swift",
            in: root
        )
        try TestSources.write(
            """
            import Alpha

            public func consume() -> Alpha.Widget {
                Alpha.Widget()
            }
            """,
            to: "Sources/Beta/Consumer.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Gizmo {
                public init() {}
            }
            """,
            to: "Sources/Alpha/Gizmo.swift",
            in: root
        )
        try TestSources.write(
            """
            public extension Gizmo {
                var size: Int { 1 }
            }
            """,
            to: "Sources/Alpha/Sizing.swift",
            in: root
        )
        try TestSources.write(
            """
            import Alpha

            public extension Gizmo {
                func ping() -> Int { 2 }
            }
            """,
            to: "Sources/Beta/Extras.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "cross-module fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// Another module's extension of its own like-named type is not this type's own, so the uses in its body are uses.
    ///
    /// Matched by written leaf name, `extension Widget` in `Beta` swallowed `Alpha.Widget`'s only cross-module uses and then said out loud that every reference to it was the type spelling its own name — a deletion unit's cue to delete a type another module builds on. The undercount is the same defect wearing a number: with a second file using it too, the verdict stayed non-zero and the swallowed file simply vanished from the list under it.
    @Test
    func aLikeNamedExtensionInAnotherModuleIsNotThisTypesOwn() async throws {
        let root = try Self.makeCrossModuleRepo()
        let engine = try SiftEngine(directory: root)
        // The fixture's store is big enough to still be opening under full-suite load.
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha.Widget", freshness: freshness)

        #expect(output.contains("used by Alpha.Widget: 4 references in 2 files — 4 production · 0 tests"))
        #expect(output.contains("Sources/Beta/Widget.swift (2):\n    :8  | func make() -> Alpha.Widget {\n    :9  | Alpha.Widget()"))
        #expect(output.contains("Sources/Beta/Consumer.swift (2):\n    :3  | public func consume() -> Alpha.Widget {\n    :4  | Alpha.Widget()"))
        // The false claim itself, which is what makes this worse than the silence the section replaced.
        #expect(!output.contains("which is the type spelling its own name"))
        #expect(!output.contains("inside its own declaration or its extensions in this module, which is not use"))
    }

    /// A nested type's extension is not the top-level type's, even in the same module, so a module check would not have settled this and the extended type's own identity has to.
    @Test
    func aNestedTypesExtensionIsNotTheTopLevelTypesOwn() async throws {
        let root = try Self.makeCrossModuleRepo()
        let engine = try SiftEngine(directory: root)
        // The fixture's store is big enough to still be opening under full-suite load.
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha.Item", freshness: freshness)

        // `extension Outer.Item` matches `LIKE '%.' || 'Item'`, so its body's uses of the top-level `Item` were dropped.
        #expect(output.contains("used by Alpha.Item: 2 references in 1 file — 2 production · 0 tests"))
        #expect(output.contains("Sources/Alpha/Nested.swift (2):\n    :8  | func boxed() -> Alpha.Item {\n    :9  | Alpha.Item()"))
        #expect(!output.contains("which is the type spelling its own name"))
    }

    /// An extension of the type written in another module is that module building on it, so it is counted as a use, while one in the type's own module stays its own — and the verdict says which rule it followed.
    ///
    /// Taken as "its own" wherever it was written, `Beta`'s extension was the type's only reference outside itself and the answer denied it out loud — "every reference recorded falls inside its own declaration or extensions" — about a type whose deletion breaks `Beta`.
    @Test
    func anExtensionInAnotherModuleIsCountedAsUse() async throws {
        let root = try Self.makeCrossModuleRepo()
        let engine = try SiftEngine(directory: root)
        // The fixture's store is big enough to still be opening under full-suite load.
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha.Gizmo", freshness: freshness)

        #expect(output.contains("used by Alpha.Gizmo: 1 reference in 1 file — 1 production · 0 tests"), "\(output)")
        #expect(output.contains("Sources/Beta/Extras.swift (1):\n    :3  | public extension Gizmo {"), "\(output)")
        // The same-module extension's header is still the type declaring itself, said as such.
        #expect(output.contains("1 more line inside its own declaration or its extensions in this module, which is not use"), "\(output)")
        #expect(!output.contains("Sources/Alpha/Sizing.swift ("), "\(output)")
        #expect(output.contains("1 extension in another module counted as use — deleting the type breaks that module"), "\(output)")
        #expect(!output.contains("no uses of Alpha.Gizmo"), "\(output)")
    }

    /// Nudges a file's mtime forward so an edit made microseconds after the last stat still reads as a change.
    private static func bumpMtime(of relativePath: String, in root: URL) throws {
        let path = root.appendingPathComponent(relativePath).path
        let current = try (FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: path)
    }

    /// When the module split the verdict reports is only a guess — a single real project whose build file stopped naming one of its own directories — the verdict says so, and still counts the extension's own further reference to the type exactly once.
    ///
    /// A build file's manifest is edited *after* the semantic index already holds `Beta`'s extension of `Alpha.Thing`, so the reference data is real while the module attribution the verdict reads is now a guess — the shape a single-target project with a type in one directory and its extension in another actually has.
    @Test
    func anExtensionWhoseModuleWasGuessedNamesTheGuessAndCountsOnce() async throws {
        // Both directories sit outside `Sources`/`Tests`, so only an explicit `path:` maps either one — the
        // convention scan never sees them, and dropping the `path:` truly unmaps a directory rather than
        // leaving the convention to re-find it, the way a `Sources/<Target>` layout would.
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Single",
                targets: [
                    .target(name: "App", path: "App"),
                    .target(name: "Shared", dependencies: ["App"], path: "Shared"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Thing {
                public init() {}
            }
            """,
            to: "App/Thing.swift",
            in: root
        )
        try TestSources.write(
            """
            import App

            public extension Thing {
                func describe() -> Thing {
                    Thing()
                }
            }
            """,
            to: "Shared/Extras.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "single real project, two directories")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        TestSources.raiseOpenBudgetForAColdStore(engine)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()

        // `Shared` drops out of the manifest without a rebuild: the semantic index built above still holds its
        // real extension of `Thing`, but nothing declares `Shared` any more, so its module is now a guess.
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Single",
                targets: [
                    .target(name: "App", path: "App"),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try Self.bumpMtime(of: "Package.swift", in: root)
        let freshness = try await engine.ensureFresh()

        let sharedFile = try engine.store.fileRow(path: "Shared/Extras.swift")
        #expect(sharedFile?.moduleGuessed == true)

        let output = try await engine.lookup(symbol: "App.Thing", freshness: freshness)

        // Its own header (line 3), the return type (line 4), and the call inside the body (line 5) — none of them
        // excluded, since only a same-module extension's own span is: an other-module extension's span (and every
        // real reference inside it, self-reference included) stays counted exactly once each, guess or no guess.
        #expect(output.contains("used by App.Thing: 3 references in 1 file — 3 production · 0 tests"), "\(output)")
        #expect(output.contains("Shared/Extras.swift (3):\n    :3  | public extension Thing {\n    :4  | func describe() -> Thing {\n    :5  | Thing()"), "\(output)")
        #expect(output.contains(
            "1 extension in another module counted as use — deleting the type breaks that module (module guessed from the path)"
        ), "\(output)")
    }
}
