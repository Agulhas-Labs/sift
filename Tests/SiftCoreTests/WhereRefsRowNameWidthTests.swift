//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a `where --refs` row naming a long enclosing declaration by its base name and `(…)`, and a short one whole.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefsRowNameWidthTests {
    /// A built package with a type used inside a function with a long labelled signature and inside a short one.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-row-name-width") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Widget: Sendable {
                    public init() {}
                }

                public func answerWithheld(_ request: Int, from sender: Int, serverGone: Bool) -> Int {
                    let made = Widget()
                    _ = made
                    return request + sender
                }

                public func bump() {
                    let made = Widget()
                    _ = made
                }
                """,
                to: "Sources/Lib/Use.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "row name width fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A name past 30 characters with a label list prints as its base name and `(…)`.
    @Test
    func aLongLabelledNameIsShortenedToItsBase() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh(), options: WhereOptions(standsInForSearch: true))

            #expect(output.contains("  answerWithheld(…)  | let made = Widget()"), "\(output)")
            #expect(!output.contains("serverGone:"), "\(output)")
        }
    }

    /// A short name keeps its whole form.
    @Test
    func aShortNameIsUnchanged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh(), options: WhereOptions(standsInForSearch: true))

            #expect(output.contains("  bump()  | let made = Widget()"), "\(output)")
        }
    }
}
