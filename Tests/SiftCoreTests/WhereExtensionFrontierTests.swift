import Foundation
import SiftCore
import Testing

/// `where` over a tree that extends a type it does not declare, with no store.
@Suite(.temporaryDirectories) struct WhereExtensionFrontierTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "A", path: "Sources/A"), .target(name: "B", path: "Sources/B"), .target(name: "Lib", path: "Sources/Lib")]
        )

        """
    }

    private static func references(of symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "extension frontier fixture, unbuilt")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A bare name the tree reaches only as the last part of a dotted extension path is answered as that extension, but an alias writing the bare name is kept, never folded in: `Depot` may be a type rather than a module.
    @Test
    func aBareNameReachedThroughADottedExtensionKeepsItsAliasesUnproven() async throws {
        let output = try await Self.references(of: "Gizmo", files: [
            "Package.swift": Self.manifest,
            "Sources/Lib/Ext.swift": "extension Depot.Gizmo {}\n",
            "Sources/Lib/Use.swift": "typealias Giz = Gizmo\n\nfunc f() {\n    _ = Giz()\n}\n",
        ])

        #expect(!output.contains("no exact match"), "\(output)")
        #expect(output.contains("_ = Giz()"), "\(output)")
        #expect(output.contains("which may be a type rather than a module"), "\(output)")
        #expect(!output.contains("folded in here"), "\(output)")
    }

    /// A dotted query for a type declared in one module keeps the aliases of an extension of the bare name written in another, which may extend some other type of the name.
    @Test
    func aDottedQueryKeepsTheAliasesOfAnExtensionInAnotherModule() async throws {
        let output = try await Self.references(of: "A.Foo", files: [
            "Package.swift": Self.manifest,
            "Sources/A/Foo.swift": "public struct Foo {}\n",
            "Sources/B/Ext.swift": "extension Foo {\n    func tuned() {}\n}\n\ntypealias F2 = B.Foo\ntypealias F5 = F2\n\nfunc f() {\n    _ = F2()\n    _ = F5()\n}\n",
        ])

        #expect(output.contains("_ = F2()"), "\(output)")
        #expect(output.contains("_ = F5()"), "\(output)")
    }
}
