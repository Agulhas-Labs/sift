//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A declaration whose name keeps its backticks in sift's index is asked of the compiler's store by the bare spelling the store records it under.
///
/// A raw identifier is stored with its backticks, because that is how Swift Testing and the compiler's diagnostics name it; the compiler's index store spells it without. Asked with the stored name, a built tree answered "no unit in the store covers it".
@Suite(.temporaryDirectories)
struct WhereBacktickedSemanticNameTests {
    static var source: String {
        """
        struct Vault {
            func `two words`() {}
            var `not allowed`: Int { 1 }
        }

        func use(_ vault: Vault) {
            vault.`two words`()
            _ = vault.`not allowed`
        }
        """
    }

    static func built(asking symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(source, to: "Sources/GizmoCore/Vault.swift", in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// The raw-identifier method resolves against the built store instead of being refused.
    @Test
    func aRawIdentifierMethodResolvesOnABuiltTree() async throws {
        let output = try await Self.built(asking: "Vault.`two words`()")

        #expect(!output.contains("REFUSED"), "\(output)")
        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.contains("  Sources/GizmoCore/Vault.swift (1):\n    :7  use(_:)  | vault.`two words`()"), "\(output)")
    }

    /// The same for a raw-identifier property.
    @Test
    func aRawIdentifierPropertyResolvesOnABuiltTree() async throws {
        let output = try await Self.built(asking: "Vault.`not allowed`")

        #expect(!output.contains("REFUSED"), "\(output)")
        #expect(output.contains("semantic: fresh"), "\(output)")
    }
}
