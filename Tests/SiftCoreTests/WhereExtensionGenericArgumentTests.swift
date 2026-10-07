//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `where` over a tree that extends a type it does not declare with generic arguments written, with no store.
@Suite(.temporaryDirectories)
struct WhereExtensionGenericArgumentTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib", path: "Sources/Lib")])

        """
    }

    /// Extensions of three framework types, two with generic arguments naming another type and one constrained by a where clause.
    private static var extensionFile: String {
        """
        import Net

        extension Dictionary<String, Net.URL> {
            func looked() -> Int { count }
        }

        extension Optional<Net.URL> {
            func unwrapped() -> Bool { self != nil }
        }

        extension Array where Element == Net.URL {
            func tallied() -> Int { count }
        }

        """
    }

    /// The `--refs` answer for `symbol` over a tree holding `files`.
    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "generic argument extension fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// The type an extension writes with generic arguments is found by its name, answered as that extension and swept by that name.
    @Test(arguments: [
        ("Dictionary", "Dictionary<String, Net.URL>", ":3"),
        ("Optional", "Optional<Net.URL>", ":7"),
    ])
    func aTypeExtendedWithGenericArgumentsIsFoundByItsName(query: String, written: String, line: String) async throws {
        let output = try await Self.references(of: query, files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.extensionFile])

        #expect(!output.contains("no exact match"), "\(output)")
        #expect(output.contains("declarations (1):\n  Lib.\(written) — extension — extension \(written) — Sources/Lib/Ext.swift\(line)-"), "\(output)")
        #expect(output.contains("\"\(query)\" used by 1 line in 1 file"), "\(output)")
        #expect(output.contains("\(line)  | extension \(written) {"), "\(output)")
    }

    /// A dotted path written with generic arguments is found by that path and by its final component.
    @Test(arguments: ["Depot.Gizmo", "Gizmo"])
    func aDottedPathWrittenWithGenericArgumentsIsFoundByItsPath(query: String) async throws {
        let output = try await Self.references(of: query, files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": "import Depot\n\nextension Depot.Gizmo<Net.URL> {}\n",
        ])

        #expect(output.contains("declarations (1):\n  Lib.Depot.Gizmo<Net.URL> — extension — extension Depot.Gizmo<Net.URL> — Sources/Lib/Ext.swift:3"), "\(output)")
    }

    /// A type named only inside the generic arguments is not what the extension extends, so it is still answered as a miss, with the extensions writing it still among the nearest symbols.
    @Test(arguments: ["URL", "Net.URL"])
    func aTypeNamedInsideTheGenericArgumentsIsNotExtended(query: String) async throws {
        let output = try await Self.references(of: query, files: ["Package.swift": Self.manifest, "Sources/Lib/Ext.swift": Self.extensionFile])

        #expect(output.contains("no exact match; nearest symbols:"), "\(output)")
        #expect(!output.contains("declarations ("), "\(output)")
        #expect(output.contains("  Dictionary<String, Net.URL> — extension — Lib — Sources/Lib/Ext.swift:3"), "\(output)")
        #expect(output.contains("  Optional<Net.URL> — extension — Lib — Sources/Lib/Ext.swift:7"), "\(output)")
    }

    /// A generic argument that is itself written with generic arguments does not make the outer extension one of its type.
    @Test
    func aNestedGenericArgumentIsNotTheExtendedType() async throws {
        let output = try await Self.references(of: "Array", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": "import Net\n\nextension Optional<Swift.Array<Net.URL>> {}\n",
        ])

        #expect(!output.contains("declarations ("), "\(output)")
        #expect(!output.contains("— extension — extension Optional"), "\(output)")
    }
}
