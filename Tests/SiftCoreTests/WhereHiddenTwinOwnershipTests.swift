//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// `where` with no store over an extension of a type's bare name in another file, where the type is declared out of that file's sight.
@Suite(.temporaryDirectories)
struct WhereHiddenTwinOwnershipTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "Lib", targets: [.target(name: "Lib", path: "Sources/Lib")])

        """
    }

    /// An extension of the bare name in a file of its own, which may extend a framework type of the name rather than the one declared.
    private static var depotFile: String {
        """
        import Foundation

        extension JSONDecoder {
            func tuned() -> Int { 1 }
        }

        """
    }

    /// The answer for `JSONDecoder` over a tree whose `Sources/Lib/Gizmo.swift` holds `gizmo`, unbuilt.
    private static func answer(gizmo: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write(gizmo, to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write(Self.depotFile, to: "Sources/Lib/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "hidden twin fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: "JSONDecoder", freshness: engine.ensureFresh())
    }

    /// A declaration private to another file, or under an `#if` the extension does not share, cannot be what the extension extends for certain, so the extension's line is a use rather than the type's own.
    @Test(arguments: ["private struct JSONDecoder {}\n", "#if os(Linux)\nstruct JSONDecoder {}\n#endif\n"])
    func anExtensionTheDeclarationIsHiddenFromIsAUse(gizmo: String) async throws {
        let output = try await Self.answer(gizmo: gizmo)

        #expect(output.contains("\"JSONDecoder\" used by 1 line in 1 file — "), "\(output)")
        #expect(output.contains("\n    :3  | extension JSONDecoder {\n"), "\(output)")
        #expect(!output.contains("inside its own declaration or its extensions in this module"), "\(output)")
    }

    /// A declaration every file of its module sees is what the extension extends, so the extension's line stays its own.
    @Test
    func anExtensionOfAVisibleDeclarationIsItsOwn() async throws {
        let output = try await Self.answer(gizmo: "struct JSONDecoder {}\n")

        #expect(output.contains("1 more line inside its own declaration or its extensions in this module, which is not use"), "\(output)")
        #expect(!output.contains("\"JSONDecoder\" used by"), "\(output)")
    }
}
