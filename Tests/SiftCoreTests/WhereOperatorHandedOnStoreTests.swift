//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An operator handed on bare, `reduce(0, <~>)`, is counted by the scan by written name on a built tree as it is with `--syntactic`: with the store answering the operator function, the operator declaration alone was scanned in the shape of a call, which a bare reference is not.
@Suite(.temporaryDirectories)
struct WhereOperatorHandedOnStoreTests {
    @Test
    func aBareOperatorIsCountedWithAStoreAsWithout() async throws {
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
        try TestSources.write(
            """
            infix operator <~>: AdditionPrecedence

            struct Vault {
                var weight: Int
            }

            func <~> (lhs: Int, rhs: Vault) -> Int { lhs + rhs.weight }
            """,
            to: "Sources/GizmoCore/Vault.swift",
            in: root
        )
        try TestSources.write(
            """
            func stock(_ vaults: [Vault]) -> Int {
                let first = 0 <~> vaults[0]
                return vaults.reduce(first, <~>)
            }
            """,
            to: "Sources/GizmoCore/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let built = try await engine.lookup(symbol: "<~>", freshness: engine.ensureFresh())
        let syntactic = try await engine.lookup(symbol: "<~>", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(built.contains("semantic: fresh"), "\(built)")
        #expect(syntactic.contains("\"<~>\" (2 call sites in 1 file"), "\(syntactic)")
        #expect(built.contains("every call spelled \"<~>\" is listed above — 2 call sites by name, 2 listed above (for <~>)"), "\(built)")
        #expect(built.components(separatedBy: "return vaults.reduce(first, <~>)").count == 2, "\(built)")
    }

    /// A prefix or postfix operator is counted the same way, whether it is applied or handed on bare.
    @Test(arguments: [
        (fixity: "prefix", name: "<~", applied: "<~vaults[0]", bare: "vaults.map(<~)"),
        (fixity: "postfix", name: "~>", applied: "vaults[0]~>", bare: "vaults.map(~>)"),
    ])
    func aBareUnaryOperatorIsCountedWithAStoreAsWithout(fixity: String, name: String, applied: String, bare: String) async throws {
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
        try TestSources.write(
            """
            \(fixity) operator \(name)

            struct Vault {
                var weight: Int
            }

            \(fixity) func \(name) (vault: Vault) -> Int { vault.weight }
            """,
            to: "Sources/GizmoCore/Vault.swift",
            in: root
        )
        try TestSources.write(
            """
            func stock(_ vaults: [Vault]) -> [Int] {
                let first = \(applied)
                return [first] + \(bare)
            }
            """,
            to: "Sources/GizmoCore/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let built = try await engine.lookup(symbol: name, freshness: engine.ensureFresh())
        let syntactic = try await engine.lookup(symbol: name, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(built.contains("semantic: fresh"), "\(built)")
        #expect(syntactic.contains("\"\(name)\" (2 call sites in 1 file"), "\(syntactic)")
        #expect(built.contains("every call spelled \"\(name)\" is listed above — 2 call sites by name, 2 listed above (for \(name))"), "\(built)")
        #expect(built.components(separatedBy: "return [first] + \(bare)").count == 2, "\(built)")
    }
}
