//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The ranges and hints a digest prints must agree with what it serves and what its target names resolve to.
@Suite(.temporaryDirectories)
struct DigestRangeHintTests {
    private static func render(_ target: String, sources: [(String, String)], moduleOf: (String) -> String) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try sources.map { try TestSources.parsed($1, path: $0, in: root) }
        try store.replaceFiles(parsed) { (moduleOf($0), false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    @Test
    func aServedDeclarationCitesFromItsFirstDocLine() throws {
        let source = """
        import Foundation

        /// Names the thing.
        ///
        /// More about it.
        struct Kicker {
            let flag: Bool
        }
        """
        let output = try Self.render("Kicker", sources: [("Sources/Alpha/Kicker.swift", source)]) { _ in "Alpha" }

        #expect(output.contains("declaration's source follows)"))
        #expect(output.contains("Kicker — Alpha — Sources/Alpha/Kicker.swift:3-8"))
        #expect(!output.contains("Kicker.swift:6-8"))
    }

    @Test
    func theOverviewHintsTheSlashOnlyForAModuleSharingATypesName() throws {
        let sources = [
            ("Sources/Kicker/Kicker.swift", "struct Kicker {\n    let flag: Bool\n}\n"),
            ("Sources/Plain/Thing.swift", "struct Thing {\n    let flag: Bool\n}\n"),
        ]
        let output = try Self.render(".", sources: sources) { $0.hasPrefix("Sources/Kicker") ? "Kicker" : "Plain" }

        #expect(output.contains("digest Kicker/ lists module Kicker"))
        #expect(!output.contains("digest Plain/"))
        #expect(output.contains("digest <Module> lists one module's declarations"))
    }
}
