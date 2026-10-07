//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `where` over a tree that extends a framework type through its array, dictionary or optional sugar, with no store.
@Suite(.temporaryDirectories)
struct WhereExtensionSugarTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib", path: "Sources/Lib")])

        """
    }

    /// Extensions written only through sugar, one of them an optional of an array.
    private static var sugarFile: String {
        """
        import Net

        extension [Net.URL] {
            func tallied() -> Int { count }
        }

        extension [String: Net.URL] {
            func looked() -> Int { count }
        }

        extension Net.URL? {
            func unwrapped() -> Bool { self != nil }
        }

        extension [Net.URL]? {
            func emptied() -> Bool { self?.isEmpty ?? true }
        }

        """
    }

    /// The `--refs` answer for `symbol` over a tree holding `files`.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "sugared extension fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// An extension written through sugar is found by the type the outermost sugar stands for.
    @Test(arguments: [
        ("Array", ["[Net.URL] — extension — extension [Net.URL] — Sources/Lib/Ext.swift:3"]),
        ("Dictionary", ["[String: Net.URL] — extension — extension [String: Net.URL] — Sources/Lib/Ext.swift:7"]),
        ("Optional", ["Net.URL? — extension — extension Net.URL? — Sources/Lib/Ext.swift:11", "[Net.URL]? — extension — extension [Net.URL]? — Sources/Lib/Ext.swift:15"]),
    ])
    func aTypeExtendedThroughItsSugarIsFoundByItsName(query: String, rows: [String]) async throws {
        let output = try await Self.references(of: query, files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.sugarFile])

        #expect(!output.contains("no exact match"), "\(output)")
        #expect(output.contains("declarations (\(rows.count)):\n"), "\(output)")
        for row in rows {
            #expect(output.contains("  Lib.\(row)"), "\(output)")
        }
    }

    /// An optional of an array is the optional's extension, never the array's.
    @Test
    func anOptionalOfAnArrayIsNotTheArraysExtension() async throws {
        let output = try await Self.references(of: "Array", files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.sugarFile])

        #expect(!output.contains("extension [Net.URL]? —"), "\(output)")
    }

    /// Beside an extension written by the type's own name, the sugared one is listed too, though its line never spells the name.
    @Test
    func aSugaredExtensionIsListedBesideOneWrittenByName() async throws {
        let output = try await Self.references(of: "Array", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": "import Net\n\nextension Array where Element == Int {}\n\nextension [Net.URL] {}\n",
        ])

        #expect(output.contains("declarations (2):\n"), "\(output)")
        #expect(output.contains("  Lib.[Net.URL] — extension — extension [Net.URL] — Sources/Lib/Ext.swift:5"), "\(output)")
    }

    /// A type named only inside the sugar is not what the extension extends, so it is still answered as a miss.
    @Test(arguments: ["URL", "Net.URL"])
    func aTypeNamedInsideTheSugarIsNotExtended(query: String) async throws {
        let output = try await Self.references(of: query, files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.sugarFile])

        #expect(output.contains("no exact match; nearest symbols:"), "\(output)")
        #expect(!output.contains("declarations ("), "\(output)")
    }
}
