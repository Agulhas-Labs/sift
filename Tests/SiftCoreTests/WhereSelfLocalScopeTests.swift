//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's calls written inside a type that a function body declares under the alias's name, where nothing at the site writes that name.
///
/// `Self` and an implied initializer there mean the body's own type, so the call is kept as unproven rather than folded in under the alias.
@Suite(.temporaryDirectories)
struct WhereSelfLocalScopeTests {
    private static let implied = "." + "init"

    private static var kept: String {
        "1 written as Sources.Crate, a typealias naming it whose name another declaration shares, kept as a use though not proven to name it, as the name may mean that other declaration where it is written"
    }

    private static var folded: String {
        "a typealias naming it, folded in here"
    }

    private static func lookup(calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo { init(_ name: String) {} }\ntypealias Crate = Gizmo", to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Gizmo.init", freshness: freshness)
    }

    private static func expectKept(_ output: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(output.contains(kept), "missing: \(kept)\n\(output)", sourceLocation: sourceLocation)
        #expect(!output.contains(folded), "unexpected: \(folded)\n\(output)", sourceLocation: sourceLocation)
    }

    @Test
    func anImpliedInitInALocalTypeOfTheNameIsKeptNotFolded() async throws {
        let output = try await Self.lookup(calling: """
        func l() {
            struct Crate {
                init(_ s: String) {}
                static func m() -> Self { \(Self.implied)("s") }
            }
        }
        """)

        Self.expectKept(output)
    }

    @Test
    func aSelfCallInALocalTypeOfTheNameIsKeptNotFolded() async throws {
        let output = try await Self.lookup(calling: """
        func l() {
            struct Crate {
                init(_ s: String) {}
                static func n() -> Self { Self("s") }
            }
        }
        """)

        Self.expectKept(output)
    }

    @Test
    func anExtensionOfTheAliasWithNoLocalTypeStaysFolded() async throws {
        let output = try await Self.lookup(calling: """
        extension Crate { static func m() -> Self { \(Self.implied)("s") } }
        """)

        #expect(output.contains(Self.folded), "\(output)")
    }
}
