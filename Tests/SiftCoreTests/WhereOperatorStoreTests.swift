//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An operator function is asked of the compiler's store by the name the store records it under, with its labels blanked, and an operator declaration — which no build records — is never refused with advice to build it.
///
/// Asked as `+(lhs:rhs:)`, a built tree answered "no unit in the store covers it; build this target", and the scan by written name then said no call was spelled.
@Suite(.temporaryDirectories)
struct WhereOperatorStoreTests {
    static func built(asking symbols: [String]) async throws -> [String] {
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
        try TestSources.write(WhereOperatorUseTests.declaring.source, to: WhereOperatorUseTests.declaring.path, in: root)
        try TestSources.write(WhereOperatorUseTests.using.source, to: WhereOperatorUseTests.using.path, in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        var answers: [String] = []
        for symbol in symbols {
            let freshness = try await engine.ensureFresh()
            try await answers.append(engine.lookup(symbol: symbol, freshness: freshness))
        }
        return answers
    }

    /// The store's own calls of each operator function are listed, and nothing is refused.
    @Test
    func operatorFunctionsResolveOnABuiltTree() async throws {
        let answers = try await Self.built(asking: ["Vault.+", "<~>", "^^"])
        let unanswered = answers.filter { $0.contains("REFUSED") || $0.contains("no call spelled") || !$0.contains("semantic: fresh") }

        #expect(unanswered.isEmpty, "\(unanswered)")
        #expect(answers[0].contains("callers of GizmoCore.Vault.+(lhs:rhs:) ("), "\(answers[0])")
        #expect(answers[0].contains("    :2  stock(_:)  | let sum = vault + vault"), "\(answers[0])")
        #expect(answers[1].contains("    :6  stock(_:)  | return (sum <~> flipped) + squared.weight + all.weight"), "\(answers[1])")
        #expect(answers[2].contains("    :4  stock(_:)  | let squared = vault^^"), "\(answers[2])")
    }
}
