//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An enum case that witnesses a protocol's static requirement is used through it, which the store records against the requirement, so its empty case is hedged and never a bare "no uses".
@Suite(.temporaryDirectories, .serialized)
struct WhereCaseWitnessHedgeTests {
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-case-witness") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Gizmo",
                    targets: [.target(name: "GizmoCore")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Styled {
                    static var standard: Self { get }
                }

                public enum Mode: Styled {
                    case standard
                    case spare
                }

                public func make<T: Styled>(_ type: T.Type) -> T {
                    T.standard
                }
                """,
                to: "Sources/GizmoCore/Mode.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "case witness fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The witnessing case names the requirement it satisfies; the case that implements nothing says plainly that nothing uses it.
    @Test
    func aWitnessingCaseIsHedgedAndAPlainOneIsNot() async throws {
        try await Self.fixture().withEngine { engine in
            let witness = try await engine.lookup(symbol: "Mode.standard", freshness: engine.ensureFresh())
            let plain = try await engine.lookup(symbol: "Mode.spare", freshness: engine.ensureFresh())

            #expect(witness.contains("it satisfies Styled.standard"), "\(witness)")
            #expect(!plain.contains("satisfies"), "\(plain)")
        }
    }
}
