//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where` lists an extension as the queried type's whatever the header writes: the bare name, generic arguments, the module, or both, for a type the tree declares and for one it only extends, with and without a store.
@Suite(.temporaryDirectories, .serialized)
struct WhereExtensionSpellingTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "App", targets: [.target(name: "App", path: "Sources/App")])

        """
    }

    /// A generic type of the tree's own, extended plainly, with generic arguments, through its module, and through both.
    private static var boxFile: String {
        """
        struct Box<T> {
            var value: T
        }

        extension Box {
            func plain() {}
        }

        extension Box<Int> {
            func ints() {}
        }

        extension App.Box<String> {
            func strings() {}
        }

        extension App.Box {
            func qualified() {}
        }

        """
    }

    /// The same framework types extended through every spelling: bare, with generic arguments, through `Swift`, through both, and with sugar.
    private static var frameworkFile: String {
        """
        extension Dictionary {
            func first() {}
        }

        extension Dictionary<String, Int> {
            func second() {}
        }

        extension Swift.Dictionary<Int, Int> {
            func third() {}
        }

        extension Swift.Dictionary {
            func fourth() {}
        }

        extension [String: Bool] {
            func fifth() {}
        }

        extension Optional {
            func sixth() {}
        }

        extension Optional<Int> {
            func seventh() {}
        }

        extension Int? {
            func eighth() {}
        }

        """
    }

    /// The headers of every extension of `Dictionary` and of `Optional` in ``frameworkFile``.
    private static let dictionaryHeaders = ["extension Dictionary —", "extension Dictionary<String, Int> —", "extension Swift.Dictionary<Int, Int> —", "extension Swift.Dictionary —", "extension [String: Bool] —"]
    private static let optionalHeaders = ["extension Optional —", "extension Optional<Int> —", "extension Int? —"]

    /// The answer for `symbol` over an unbuilt tree holding `files`.
    private static func noStoreAnswer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "extension spellings, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// The declarations block of an answer: its heading and its rows.
    private static func declarationsBlock(of output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("declarations (") }) else { return [] }
        return Array(lines[start...].prefix { !$0.isEmpty })
    }

    /// The `extensions of` block of an answer: its heading and its rows.
    private static func extensionsBlock(of output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("extensions of ") }) else { return [] }
        return Array(lines[start...].prefix { !$0.isEmpty })
    }

    // MARK: A type of the tree's own

    /// With no store, every extension of `Box` is listed under it whatever its header writes, and its lines are counted as its own rather than as uses.
    @Test(arguments: ["Box", "App.Box"])
    func everySpellingOfATreeTypeIsItsExtensionWithNoStore(query: String) async throws {
        let output = try await Self.noStoreAnswer(query, files: ["Package.swift": Self.manifest, "Sources/App/Box.swift": Self.boxFile])

        #expect(Self.extensionsBlock(of: output) == [
            "extensions of Box (4):",
            "  extension Box — 1 members — Sources/App/Box.swift:5-7",
            "  extension Box<Int> — 1 members — Sources/App/Box.swift:9-11",
            "  extension App.Box<String> — 1 members — Sources/App/Box.swift:13-15",
            "  extension App.Box — 1 members — Sources/App/Box.swift:17-19",
        ], "\(output)")
        #expect(!output.contains(":9  | extension Box<Int> {"), "\(output)")
        #expect(!output.contains(":13  | extension App.Box<String> {"), "\(output)")
        #expect(output.contains("no use spelled \"Box\" anywhere"), "\(output)")
        #expect(output.contains("; 4 more lines inside its own declaration or its extensions in this module, which is not use (for App.Box)"), "\(output)")
    }

    /// With a store, the same four are listed, and the headers the store records against `Box` count as its own lines, never as uses.
    @Test(arguments: ["Box", "App.Box"])
    func everySpellingOfATreeTypeIsItsExtensionWithAStore(query: String) async throws {
        try await Self.builtFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: query, freshness: engine.ensureFresh())

            #expect(output.contains("mode: syntactic + semantic"), "\(output)")
            #expect(Self.extensionsBlock(of: output) == [
                "extensions of Box (4):",
                "  extension Box — 1 members — Sources/App/Box.swift:5-7",
                "  extension Box<Int> — 1 members — Sources/App/Box.swift:9-11",
                "  extension App.Box<String> — 1 members — Sources/App/Box.swift:13-15",
                "  extension App.Box — 1 members — Sources/App/Box.swift:17-19",
            ], "\(output)")
            #expect(!output.contains(":9  | extension Box<Int> {"), "\(output)")
            #expect(!output.contains(":13  | extension App.Box<String> {"), "\(output)")
            #expect(output.contains("no uses of App.Box recorded in the store — every reference recorded falls inside its own declaration or its extensions in this module"), "\(output)")
        }
    }

    /// The package of ``boxFile`` and ``frameworkFile``, built once for the suite.
    private static func builtFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-extension-spelling") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write(boxFile, to: "Sources/App/Box.swift", in: root)
            try TestSources.write(frameworkFile, to: "Sources/App/Framework.swift", in: root)
            try TestSources.commitAll(in: root, message: "extension spellings")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    // MARK: A type the tree only extends

    /// With no store, a query through `Swift` lists the same extensions as the bare one.
    @Test(arguments: [("Dictionary", dictionaryHeaders), ("Optional", optionalHeaders)])
    func aQueryThroughSwiftListsWhatTheBareQueryListsWithNoStore(name: String, headers: [String]) async throws {
        let files = ["Package.swift": Self.manifest, "Sources/App/Framework.swift": Self.frameworkFile]
        let bare = try await Self.noStoreAnswer(name, files: files)
        let qualified = try await Self.noStoreAnswer("Swift.\(name)", files: files)

        #expect(Set(Self.declarationsBlock(of: bare)) == Set(Self.declarationsBlock(of: qualified)), "\(bare)\n\(qualified)")
        #expect(!qualified.contains("could not resolve"), "\(qualified)")
        for answer in [bare, qualified] {
            let block = Self.declarationsBlock(of: answer)
            #expect(block.first == "declarations (\(headers.count)):", "\(answer)")
            for header in headers {
                #expect(block.contains { $0.contains("— extension — \(header)") }, "\(header) in \(answer)")
            }
        }
    }

    /// With a store, a query through `Swift` lists the same extensions as the bare one.
    @Test(arguments: [("Dictionary", dictionaryHeaders), ("Optional", optionalHeaders)])
    func aQueryThroughSwiftListsWhatTheBareQueryListsWithAStore(name: String, headers: [String]) async throws {
        try await Self.builtFixture().withEngine { engine in
            let bare = try await engine.lookup(symbol: name, freshness: engine.ensureFresh())
            let qualified = try await engine.lookup(symbol: "Swift.\(name)", freshness: engine.ensureFresh())

            #expect(qualified.contains("mode: syntactic + semantic"), "\(qualified)")
            for answer in [bare, qualified] {
                let block = Self.declarationsBlock(of: answer)
                #expect(block.first == "declarations (\(headers.count)):", "\(answer)")
                for header in headers {
                    #expect(block.contains { $0.contains("— extension — \(header)") }, "\(header) in \(answer)")
                }
            }
            #expect(Set(Self.declarationsBlock(of: bare)) == Set(Self.declarationsBlock(of: qualified)), "\(bare)\n\(qualified)")
            #expect(!qualified.contains("could not resolve"), "\(qualified)")
        }
    }

    /// A bare extension in a module that declares its own type of the name extends that type, so a query through another module leaves it out; one written through that other module stays.
    @Test
    func aQueryThroughSwiftLeavesOutAnExtensionOfTheModulesOwnType() async throws {
        let output = try await Self.noStoreAnswer("Swift.Dictionary", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Dictionary.swift": "struct Dictionary {}\n\nextension Dictionary {\n    func own() {}\n}\n\nextension Swift.Dictionary {\n    func framework() {}\n}\n",
        ])

        #expect(Self.declarationsBlock(of: output) == [
            "declarations (1):",
            "  App.Swift.Dictionary — extension — extension Swift.Dictionary — Sources/App/Dictionary.swift:7-9",
        ], "\(output)")
    }

    /// An extension written through another qualifier extends another type of the name, so a query through `Swift` leaves it out.
    @Test
    func aQueryThroughSwiftLeavesOutAnExtensionThroughAnotherQualifier() async throws {
        let output = try await Self.noStoreAnswer("Swift.Dictionary", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Other.swift": "import Shelf\n\nextension Shelf.Dictionary<Int> {}\n\nextension Dictionary {}\n",
        ])

        #expect(Self.declarationsBlock(of: output) == [
            "declarations (1):",
            "  App.Dictionary — extension — extension Dictionary — Sources/App/Other.swift:5",
        ], "\(output)")
    }

    /// A leading name the tree extends, aliases or declares is a type, not a module, so a bare extension of the final name, which never names a nested type, is left out.
    @Test(arguments: ["extension Depot {}", "extension Depot<Int> {}", "typealias Depot = Shelf.Depot", "enum Depot {}"])
    func aLeadingNameTheTreeWritesAsATypeIsNoModule(leading: String) async throws {
        let output = try await Self.noStoreAnswer("Depot.Gizmo", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Depot.swift": "import Shelf\n\n\(leading)\n\nextension Depot.Gizmo {}\n\nextension Gizmo {}\n",
        ])

        #expect(output.contains("— extension — extension Depot.Gizmo — Sources/App/Depot.swift:5"), "\(output)")
        #expect(!output.contains("extension Gizmo —"), "\(output)")
    }

    // MARK: Types of one name in several modules

    /// `Other` declares a `Box`, `App` declares its own beside it and extends both, `Kit` imports `Other` and extends its `Box` bare, and `Alias` imports `App` and extends its own typealias `Box` of `Int`.
    private static var moduleFiles: [String: String] {
        [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [
                .target(name: "Other", path: "Sources/Other"),
                .target(name: "App", dependencies: ["Other"], path: "Sources/App"),
                .target(name: "Kit", dependencies: ["Other"], path: "Sources/Kit"),
                .target(name: "Alias", dependencies: ["App"], path: "Sources/Alias"),
            ])

            """,
            "Sources/Other/Box.swift": "public struct Box {\n    public init() {}\n}\n\nextension Box {\n    func own() {}\n}\n",
            "Sources/App/Box.swift": """
            import Other

            struct Box<T> {
                var value: T
            }

            extension Box<Int> {
                func ints() {}
            }

            extension App.Box<String> {
                func strings() {}
            }

            extension Other.Box {
                func other() {}
            }

            enum Outer {
                struct Box {}
            }

            extension Outer.Box {
                func outer() {}
            }

            """,
            "Sources/App/Stored.swift": "protocol Stored {}\n\ntypealias Kept = Stored\n\nextension Box<Int>: Kept {}\n",
            "Sources/Kit/Box.swift": "import Other\n\nextension Box {\n    func kit() {}\n}\n",
            "Sources/Alias/Box.swift": "import App\n\ntypealias Box = Int\n\nextension Box {\n    func alias() {}\n}\n",
        ]
    }

    /// The extensions of `Other`'s `Box`: one written through `Other`, one bare in a module importing it that declares no `Box`, and one bare in `Other` itself.
    private static let otherBoxBlock = [
        "extensions of Box (3):",
        "  extension Other.Box — 1 members — Sources/App/Box.swift:15-17",
        "  extension Box — 1 members — Sources/Kit/Box.swift:3-5",
        "  extension Box — 1 members — Sources/Other/Box.swift:5-7",
    ]

    /// The package of ``moduleFiles``, built once for the suite.
    private static func builtModules() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-extension-modules") { root in
            for (path, source) in moduleFiles {
                try TestSources.write(source, to: path, in: root)
            }
            try TestSources.commitAll(in: root, message: "extensions across modules")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The `extensions of` block under each module's `Box` with a store: an extension the code places as the other module's type, or a nested one's, is not listed.
    @Test
    func aQualifiedQueryListsTheExtensionsOfItsOwnModulesTypeWithAStore() async throws {
        try await Self.builtModules().withEngine { engine in
            let other = try await engine.lookup(symbol: "Other.Box", freshness: engine.ensureFresh())
            let app = try await engine.lookup(symbol: "App.Box", freshness: engine.ensureFresh())

            #expect(other.contains("mode: syntactic + semantic"), "\(other)")
            #expect(Self.extensionsBlock(of: other) == Self.otherBoxBlock, "\(other)")
            Self.expectAppBoxBlock(of: app)
        }
    }

    /// The same blocks with no store, and the lines each `Box` counts as its own or as another module's use of it follow the same placement.
    @Test
    func aQualifiedQueryListsTheExtensionsOfItsOwnModulesTypeWithNoStore() async throws {
        let other = try await Self.noStoreAnswer("Other.Box", files: Self.moduleFiles)
        let app = try await Self.noStoreAnswer("App.Box", files: Self.moduleFiles)

        #expect(Self.extensionsBlock(of: other) == Self.otherBoxBlock, "\(other)")
        #expect(other.contains("; 2 extensions in other modules counted as uses — deleting the type breaks those modules (for Other.Box)"), "\(other)")
        Self.expectAppBoxBlock(of: app)
        #expect(!app.contains("counted as use"), "\(app)")
    }

    /// `App`'s `Box` lists its own three extensions and none of `Other`'s, `Kit`'s or `Outer`'s.
    private static func expectAppBoxBlock(of output: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let block = extensionsBlock(of: output)
        #expect(block.first == "extensions of Box (3):", "\(output)", sourceLocation: sourceLocation)
        for row in ["  extension Box<Int> — 1 members — Sources/App/Box.swift:7-9", "  extension App.Box<String> — 1 members — Sources/App/Box.swift:11-13"] {
            #expect(block.contains(row), "\(row) in \(output)", sourceLocation: sourceLocation)
        }
        #expect(block.contains { $0.contains("Sources/App/Stored.swift:5") }, "\(output)", sourceLocation: sourceLocation)
        #expect(!block.contains { $0.contains("Other.Box") || $0.contains("Outer.Box") || $0.contains("Sources/Kit/") || $0.contains("Sources/Other/") }, "\(output)", sourceLocation: sourceLocation)
    }

    /// An extension written through a name the tree has as neither a module nor a type may extend another module's type of the name, so it is listed and marked.
    @Test
    func anExtensionTheCodeCannotPlaceIsListedAndMarked() async throws {
        let output = try await Self.noStoreAnswer("Box", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Box.swift": "import Shelf\n\nstruct Box {}\n\nextension Shelf.Box<Int> {}\n\nextension Box {}\n",
        ])

        #expect(Self.extensionsBlock(of: output) == [
            "extensions of Box (2):",
            "  extension Shelf.Box<Int> — 0 members — Sources/App/Box.swift:5 — may extend another module's Box",
            "  extension Box — 0 members — Sources/App/Box.swift:7",
        ], "\(output)")
    }

    /// A conformance written with generic arguments through a typealias of the protocol is listed once, with its extension's row, rather than also as a bare store hit.
    @Test
    func aConformanceWrittenWithGenericArgumentsHasItsRow() async throws {
        try await Self.builtModules().withEngine { engine in
            let output = try await engine.lookup(symbol: "Stored", freshness: engine.ensureFresh())

            #expect(output.contains("mode: syntactic + semantic"), "\(output)")
            #expect(output.contains("\nconformers of Stored (1: 0 direct, 0 indirect, 1 through a typealias"), "\(output)")
            #expect(output.contains("\n  App.Box<Int> — extension — Sources/App/Stored.swift:5 — through typealias App.Kept"), "\(output)")
            #expect(!output.contains("\n  Box — Sources/App/Stored.swift:5"), "\(output)")
        }
    }

    /// A typealias written through a dotted extension's path with generic arguments is followed as one without them, so a use of the alias is kept.
    @Test
    func anAliasThroughAGenericDottedExtensionKeepsItsUse() async throws {
        let output = try await Self.noStoreAnswer("Box", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Box.swift": "import Shelf\n\nstruct Box {}\n\nextension Shelf.Box<Int> {}\n\ntypealias Crate = Shelf.Box\n\nfunc make() {\n    _ = Crate()\n}\n",
        ])

        #expect(output.contains("\n    :10  | _ = Crate()"), "\(output)")
    }

    // MARK: Placement read through a typealias, a nesting and the use sweep

    /// A bare extension in a module declaring its own typealias of the name extends what the alias names, never an import's type, so `Alias`'s extension of `Int` is not `App`'s `Box`'s, with a store or without, and neither counts it as a use.
    @Test
    func anExtensionThroughItsModulesOwnTypealiasIsNotAnImportsType() async throws {
        let noStore = try await Self.noStoreAnswer("App.Box", files: Self.moduleFiles)
        try await Self.builtModules().withEngine { engine in
            let stored = try await engine.lookup(symbol: "App.Box", freshness: engine.ensureFresh())

            #expect(stored.contains("mode: syntactic + semantic"), "\(stored)")
            for output in [stored, noStore] {
                #expect(!Self.extensionsBlock(of: output).contains { $0.contains("Sources/Alias/") }, "\(output)")
                #expect(!output.contains("counted as use"), "\(output)")
            }
        }
    }

    /// `App` and `Other` each declare a `Box`, and `Alias` imports both and extends its own typealias `Box` of `target`.
    private static func aliasFiles(target: String) -> [String: String] {
        [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [
                .target(name: "App", path: "Sources/App"),
                .target(name: "Other", path: "Sources/Other"),
                .target(name: "Alias", dependencies: ["App", "Other"], path: "Sources/Alias"),
            ])

            """,
            "Sources/App/Box.swift": "public struct Box {}\n",
            "Sources/Other/Box.swift": "public struct Box {}\n",
            "Sources/Alias/Box.swift": "import App\nimport Other\n\ntypealias Box = \(target)\n\nextension Box {}\n",
        ]
    }

    /// The alias's target decides: one naming the asked type makes the extension its own, listed unmarked, though two imports declare a `Box`.
    @Test
    func anExtensionThroughAnAliasOfTheAskedTypeIsItsOwn() async throws {
        let output = try await Self.noStoreAnswer("App.Box", files: Self.aliasFiles(target: "App.Box"))

        #expect(Self.extensionsBlock(of: output).contains("  extension Box — 0 members — Sources/Alias/Box.swift:6"), "\(output)")
    }

    /// An alias of a type of no plain path, or of a path naming no type of the asked name, makes the extension another type's: neither listed nor counted as a use.
    @Test(arguments: ["Int", "[Int]", "Int?"])
    func anExtensionThroughAnAliasOfAnotherTypeIsNotListed(target: String) async throws {
        let output = try await Self.noStoreAnswer("App.Box", files: Self.aliasFiles(target: target))

        #expect(!Self.extensionsBlock(of: output).contains { $0.contains("Sources/Alias/") }, "\(output)")
        #expect(!output.contains("counted as use"), "\(output)")
    }

    /// A `private` typealias names nothing outside its file: in another file of the same module, `Box` is the imported type, and the extension is its own.
    @Test(arguments: ["private", "fileprivate"])
    func aFilePrivateAliasLeavesTheOtherFilesExtensionTheImportedTypes(access: String) async throws {
        let output = try await Self.noStoreAnswer("App.Box", files: [
            "Package.swift": """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [
                .target(name: "App", path: "Sources/App"),
                .target(name: "Alias", dependencies: ["App"], path: "Sources/Alias"),
            ])

            """,
            "Sources/App/Box.swift": "public struct Box {}\n",
            "Sources/Alias/Hidden.swift": "\(access) typealias Box = Int\n",
            "Sources/Alias/Box.swift": "import App\n\nextension Box {}\n",
        ])

        #expect(Self.extensionsBlock(of: output).contains("  extension Box — 0 members — Sources/Alias/Box.swift:3"), "\(output)")
        #expect(!output.contains("extends another module's Box"), "\(output)")
    }

    /// A bare extension the code cannot place is still not a nested type's: at file scope `Box` never names `Outer.Box`.
    @Test
    func aBareExtensionIsNoNestedTypes() async throws {
        let output = try await Self.noStoreAnswer("Outer.Box", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Box.swift": "enum Outer {\n    struct Box {}\n}\n\nextension Outer.Box {}\n",
            "Sources/App/Loose.swift": "import Shelf\n\nextension Box {}\n",
        ])

        #expect(Self.extensionsBlock(of: output) == [
            "extensions of Box (1):",
            "  extension Outer.Box — 0 members — Sources/App/Box.swift:5",
        ], "\(output)")
    }

    /// With no store, the use sweep keeps a bare extension's header placed as another module's type, and says so on its line and beside the count.
    @Test
    func theUseSweepLabelsAnExtensionPlacedAsAnotherType() async throws {
        let other = try await Self.noStoreAnswer("Other.Box", files: Self.moduleFiles)
        let app = try await Self.noStoreAnswer("App.Box", files: Self.moduleFiles)

        #expect(other.contains("\n    :7  | extension Box<Int> { — extends another module's Box\n"), "\(other)")
        #expect(other.contains("\n    :3  | extension Box {\n"), "\(other)")
        #expect(other.contains("; 3 of them write \"Box\" as the header of an extension the index places as another type's, so extend that type rather than this struct"), "\(other)")
        #expect(app.contains("\n  Sources/Kit/Box.swift (1):\n    :3  | extension Box { — extends another module's Box\n"), "\(app)")
        #expect(app.contains("; 3 of them write \"Box\" as the header of an extension the index places as another type's"), "\(app)")
    }
}
