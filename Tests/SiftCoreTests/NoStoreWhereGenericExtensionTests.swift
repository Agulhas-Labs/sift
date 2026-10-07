//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With no index store, `where` keeps every site the written name reaches: an extension written with generic arguments is listed beside a plain extension of the same type, and `@MainActor` hides no name another module's macro of that name may introduce.
@Suite(.temporaryDirectories)
struct NoStoreWhereGenericExtensionTests {
    private static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A plain extension beside ones written with generic arguments, bare and qualified.
    private static var extensions: String {
        """
        extension Dictionary<String, Net.URL> {
            func first() -> Int { 1 }
        }
        extension Swift.Dictionary<String, Int> {
            func second() -> Int { 2 }
        }
        extension Dictionary {
            func third() -> Int { 3 }
        }
        extension Optional<Net.URL> {
            func fourth() -> Int { 4 }
        }
        extension Optional {
            func fifth() -> Int { 5 }
        }
        extension Array<Int> {
            func sixth() -> Int { 6 }
        }
        extension Swift.Array<Int> {
            func seventh() -> Int { 7 }
        }
        extension Array {
            func eighth() -> Int { 8 }
        }

        """
    }

    /// The query resolving to a plain extension must not stop the extensions written with generic arguments joining it.
    @Test(arguments: [
        ("Dictionary", ["extension Dictionary<String, Net.URL> —", "extension Swift.Dictionary<String, Int> —", "extension Dictionary —"]),
        ("Optional", ["extension Optional<Net.URL> —", "extension Optional —"]),
        ("Array", ["extension Array<Int> —", "extension Swift.Array<Int> —", "extension Array —"]),
    ])
    func aGenericExtensionIsListedBesideAPlainOne(symbol: String, declarations: [String]) async throws {
        let output = try await Self.answer(symbol, files: ["Sources/App/Extensions.swift": Self.extensions])

        for declaration in declarations {
            #expect(output.contains(declaration), "\(symbol): \(declaration)\n\(output)")
        }
    }

    /// A qualified query reaches the extensions written with generic arguments too.
    @Test
    func aQualifiedQueryReachesTheGenericExtension() async throws {
        let output = try await Self.answer("Swift.Dictionary", files: ["Sources/App/Extensions.swift": Self.extensions])

        #expect(output.contains("extension Swift.Dictionary<String, Int> —"), "\(output)")
    }

    private static var nested: String {
        """
        import Foundation
        enum Net { struct URL { var text = "" } }
        func home() -> URL? { nil }

        """
    }

    /// Another module's `macro MainActor()` naming `URL` is applied to `@MainActor`, so with none declared in the tree the bare `URL` lines stay uses.
    @Test
    func mainActorHidesNoNameWhenTheMacroIsOutsideTheTree() async throws {
        let output = try await Self.answer("Net.URL", files: [
            "Sources/App/Net.swift": Self.nested,
            "Sources/App/Run.swift": "@MainActor func run() {}\n",
        ])

        #expect(output.contains(":3  | func home() -> URL? { nil }"), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// A tree declaring `macro MainActor` with `names: named(URL)` beside a `@MainActor` use keeps the site.
    @Test
    func aDeclaredMainActorMacroNamingURLKeepsTheSite() async throws {
        let output = try await Self.answer("Net.URL", files: [
            "Sources/App/Net.swift": Self.nested,
            "Sources/App/Macro.swift": "@attached(peer, names: named(URL))\nmacro MainActor() = #externalMacro(module: \"Macros\", type: \"Gizmo\")\n",
            "Sources/App/Run.swift": "@MainActor func run() {}\n",
        ])

        #expect(output.contains(":3  | func home() -> URL? { nil }"), "\(output)")
        #expect(!output.contains("so not use"), "\(output)")
    }

    /// A `@MainActor` on a declaration inside a function body hides no name either: it reads as `@Gizmo` does, so the bare `URL` line stays a use.
    @Test
    func mainActorInsideABodyKeepsTheLine() async throws {
        for attribute in ["@MainActor", "@Gizmo"] {
            let output = try await Self.answer("Net.URL", files: [
                "Sources/App/Net.swift": "enum Net { struct URL {} }\n",
                "Sources/App/Run.swift": "func outer() {\n    \(attribute) func g() {}\n    let u: URL? = nil\n}\n",
            ])

            #expect(output.contains(":3  | let u: URL? = nil"), "\(attribute): \(output)")
            #expect(!output.contains("so not use"), "\(attribute): \(output)")
        }
    }
}
