//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With no index store, an extension is matched by the path it writes: one written through a dotted path is found by its own spelling and swept by its final component, and one of a type the tree declares only nested elsewhere is swept beside that type rather than folded into it, its owner named once.
@Suite(.temporaryDirectories)
struct NoStoreExtensionPathTests {
    private static func answer(_ symbol: String, files: [String: String], worktree: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: TestSources.makeWorktree(of: root, named: worktree))
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    @Test
    func aDottedExtensionIsFoundByItsOwnSpellingAndSwept() async throws {
        let output = try await Self.answer("Depot.Gizmo", files: [
            "Sources/App/Gizmo.swift": "extension Depot.Gizmo {\n    var label: String { \"\" }\n}\n",
            "Sources/App/Shelf.swift": "let gizmo: Depot.Gizmo? = nil\n",
        ], worktree: "agent-3c4d5e6f")

        #expect(!output.contains("no exact match"), "\(output)")
        #expect(output.contains("declarations (1):"), "\(output)")
        #expect(output.contains("references: all sites by written name, paged by file"), "\(output)")
        #expect(output.contains(":1  | extension Depot.Gizmo {"), "\(output)")
        #expect(output.contains(":1  | let gizmo: Depot.Gizmo? = nil"), "\(output)")
    }

    @Test
    func twoExtensionsOfOneUndeclaredTypeNameTheirOwnerOnce() async throws {
        let output = try await Self.answer("URL", files: [
            "Sources/App/Label.swift": "import Foundation\n\nextension URL {\n    var label: String { path }\n}\n",
            "Sources/App/Secure.swift": "import Foundation\n\nextension URL {\n    var secure: Bool { scheme == \"https\" }\n}\n",
        ], worktree: "agent-4d5e6f70")

        #expect(output.contains("(for Sources.URL):"), "\(output)")
        #expect(!output.contains("Sources.URL, Sources.URL"), "\(output)")
    }

    /// The extension extends the framework's type, which a bare name outside the nesting type means, so both are named for the lines writing the name.
    @Test
    func anExtensionOfATypeNestedElsewhereIsSweptBesideIt() async throws {
        let output = try await Self.answer("URL", files: [
            "Sources/App/Endpoint.swift": "import Foundation\n\nenum Endpoint {\n    struct URL {\n        let raw: String\n    }\n}\n\nfunc home() -> URL? {\n    URL(string: \"/\")\n}\n",
            "Sources/App/Secure.swift": "import Foundation\n\nextension URL {\n    var secure: Bool { scheme == \"https\" }\n}\n",
        ], worktree: "agent-5e6f7081")

        #expect(output.contains("(for Sources.Endpoint.URL, Sources.URL):"), "\(output)")
        #expect(output.contains(":9  | func home() -> URL? {"), "\(output)")
    }
}
