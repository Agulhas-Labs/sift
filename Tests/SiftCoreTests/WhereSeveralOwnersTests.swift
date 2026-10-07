//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A bare name several unrelated owners declare is answered with its declarations and the query that narrows to each, and no use listings.
@Suite(.temporaryDirectories)
struct WhereSeveralOwnersTests {
    private static var types: String {
        """
        struct Depot {
            func load(_ value: Int) {}
            func load(_ value: String) {}
        }
        struct Orchard {
            func load(_ value: Int) {}
            func tend() { load(1) }
        }
        class Base {
            func greet() {}
        }
        class Child: Base {
            override func greet() {}
        }
        """
    }

    private static var calls: String {
        """
        struct Calls {
            func typed(_ depot: Depot) { depot.load(3); depot.load("x") }
            func made() { Orchard().load(4) }
            func said() { Child().greet() }
        }
        """
    }

    private static func answer(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(types, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup(symbol, in: root)
    }

    /// Two owners' declarations are listed one per line with the query that narrows to each owner, and no use is listed.
    @Test
    func aBareNameOfTwoOwnersListsDeclarationsAndNarrowingQueries() async throws {
        let output = try await Self.answer("load")

        #expect(output.contains("declarations (3) under 2 owners"))
        let rows = output.split(separator: "\n").filter { $0.contains(" — where ") }
        #expect(rows.count == 3)
        #expect(rows.filter { $0.hasSuffix("— where Depot.load") }.count == 2)
        #expect(rows.filter { $0.hasSuffix("— where Orchard.load") }.count == 1)
        #expect(output.contains("uses: not counted — only the index store tells which of these a use names"))
        #expect(!output.contains("call sites"))
        #expect(!output.contains("in Calls.made()"))
        #expect(!output.contains("in Orchard.tend()"))
    }

    /// A qualified query answers as it always has, its name-matched sites listed.
    @Test
    func aQualifiedQueryStillListsItsSites() async throws {
        let output = try await Self.answer("Orchard.load")

        #expect(output.contains("declarations (1):"))
        #expect(!output.contains("under 2 owners"))
        #expect(output.contains("in Orchard.tend()"))
        #expect(output.contains("in Calls.made()"))
    }

    /// Overloads of one owner are one owner, and keep the answer that lists their sites.
    @Test
    func overloadsOfOneOwnerKeepTheirSites() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Depot {\n    func stock(_ value: Int) {}\n    func stock(_ value: String) {}\n    func fill() { stock(1) }\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await CallSiteHeadingTests.lookup("stock", in: root)

        #expect(output.contains("declarations (2):"))
        #expect(!output.contains("owners"))
        #expect(output.contains("in Depot.fill()"))
    }

    /// An override and the member it overrides are one owner through the written inheritance, and keep their sites.
    @Test
    func anOverrideIsNotAnotherOwner() async throws {
        let output = try await Self.answer("greet")

        #expect(output.contains("declarations (2):"))
        #expect(!output.contains("owners"))
        #expect(output.contains("in Calls.said()"))
    }

    /// Free functions of one name in two modules are two owners, each narrowed by its module.
    @Test
    func freeFunctionsInTwoModulesAreNarrowedByModule() async throws {
        let root = try TestSources.makeTempRepo()
        let manifest = "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Pair\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\")])\n"
        try TestSources.write(manifest, to: "Package.swift", in: root)
        try TestSources.write("func settle() {}\nfunc use() { settle() }\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try TestSources.write("func settle() {}\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await CallSiteHeadingTests.lookup("settle", in: root)

        #expect(output.contains("declarations (2) under 2 owners"))
        #expect(output.contains("Sources/Alpha/Alpha.swift:1 — where Alpha.settle"))
        #expect(output.contains("Sources/Beta/Beta.swift:1 — where Beta.settle"))
        #expect(!output.contains("in Alpha.use()"))
    }

    /// With a store, each declaration carries its own use count split on the file's imports, and still no listing.
    @Test
    func aStoreCountsEachOwnersUses() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.types, to: "Sources/Lib/Types.swift", in: root)
        try TestSources.write(Self.calls, to: "Sources/Lib/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "load", freshness: freshness)

        #expect(output.contains("semantic: fresh"))
        #expect(output.contains("Lib.Orchard.load(_:) — func — Sources/Lib/Types.swift:6 — 2 call sites: 2 production · 0 tests — where Orchard.load"))
        #expect(output.contains("— 1 call site: 1 production · 0 tests — where Depot.load"))
        #expect(!output.contains("callers of"))
        #expect(!output.contains("uses: not counted"))
    }

    /// The bare-name answer over the files given, keyed by repository-relative path, in a package of two modules.
    private static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        let manifest = "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Pair\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\")])\n"
        try TestSources.write(manifest, to: "Package.swift", in: root)
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup(symbol, in: root)
    }

    /// Two unrelated types that share a name, one in each module, are two owners, each narrowed by its module.
    @Test
    func sameNamedTypesInTwoModulesAreTwoOwners() async throws {
        let source = "struct Config {\n    func load() {}\n}\n"
        let output = try await Self.answer("load", files: ["Sources/Alpha/Config.swift": source, "Sources/Beta/Config.swift": source])

        #expect(output.contains("declarations (2) under 2 owners"))
        #expect(output.contains("— where Alpha.Config.load"))
        #expect(output.contains("— where Beta.Config.load"))
    }

    /// Two nested types that share a name under different containers are two owners, each narrowed by its container.
    @Test
    func sameNamedNestedTypesAreTwoOwners() async throws {
        let source = "struct Outer {\n    struct Detail {\n        func load() {}\n    }\n}\nstruct Other {\n    struct Detail {\n        func load() {}\n    }\n}\n"
        let output = try await Self.answer("load", files: ["Sources/Alpha/Detail.swift": source])

        #expect(output.contains("declarations (2) under 2 owners"))
        #expect(output.contains("— where Outer.Detail.load"))
        #expect(output.contains("— where Other.Detail.load"))
    }

    /// An extension in another module is the type it extends, so its member and the type's own are one owner; where its own module declares a type of that name, it is that one.
    @Test
    func anExtensionIsTheOwnerOfTheTypeItExtends() async throws {
        let config = "public struct Config {\n    public func load() {}\n}\n"
        let extended = "import Alpha\nextension Config {\n    func load(_ value: Int) {}\n}\n"
        let across = try await Self.answer("load", files: ["Sources/Alpha/Config.swift": config, "Sources/Beta/More.swift": extended])

        #expect(across.contains("declarations (2):"))
        #expect(!across.contains("owners"))

        let shadowed = try await Self.answer("load", files: [
            "Sources/Alpha/Config.swift": config,
            "Sources/Beta/Config.swift": "struct Config {}\n",
            "Sources/Beta/More.swift": extended,
        ])

        #expect(shadowed.contains("declarations (2) under 2 owners"))
        #expect(shadowed.contains("— where Alpha.Config.load"))
        #expect(shadowed.contains("— where Beta.Config.load"))
    }

    /// A witness in a conforming extension, an override of a base written qualified, and one of a base written with generic arguments are each one owner with what they implement.
    @Test(arguments: [
        "protocol Loader {\n    func greet()\n}\nstruct Crate {}\nextension Crate: Loader {\n    func greet() {}\n}\n",
        "enum Realm {\n    class Base {\n        func greet() {}\n    }\n}\nclass Scion: Realm.Base {\n    override func greet() {}\n}\n",
        "class Gen<T> {\n    func greet() {}\n}\nclass Heir: Gen<Int> {\n    override func greet() {}\n}\n",
    ])
    func aWrittenRelationJoinsTheOwners(source: String) async throws {
        let output = try await Self.answer("greet", files: ["Sources/Alpha/Kinds.swift": source])

        #expect(output.contains("declarations (2):"))
        #expect(!output.contains("owners"))
    }
}
