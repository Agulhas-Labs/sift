//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a line writing two alias names a nearer declaration shadows, with no index store.
///
/// The line is one line, so it is counted once, under the first of the names in name order, and the clause of a later name does not count it again.
@Suite(.temporaryDirectories)
struct WhereAliasShadowOverlapTests {
    private static var base: String {
        """
        struct Gizmo {
            init(_ name: String) {}
        }
        struct Other {
            init(_ name: String) {}
        }
        typealias Crate = Gizmo
        typealias Bin = Gizmo
        """
    }

    private static var space: String {
        """
        enum Space {
            typealias Crate = Other
            typealias Bin = Other
        }
        """
    }

    private static func lookup(declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Gizmo", freshness: freshness)
    }

    /// Whether `output` holds `clause` whole, as one of the clauses a count line opens with " — ", joins with "; " or closes with " (for".
    private static func holdsClause(_ clause: String, in output: String) -> Bool {
        ["; " + clause + ";", "; " + clause + " (for", " — " + clause + ";", " — " + clause + " (for"].contains { output.contains($0) }
    }

    private static func typeClause(_ alias: String, count: Int = 1) -> String {
        "\(count) more line\(count == 1 ? "" : "s") writing \"\(alias)\" bare inside a type that declares its own \"\(alias)\", which is what the name means there, so not use"
    }

    private static func functionClause(_ alias: String, count: Int = 1) -> String {
        "\(count) more line\(count == 1 ? "" : "s") writing \"\(alias)\" bare inside a function that declares its own \"\(alias)\", which is what the name means there, so not use"
    }

    /// A line writing two aliases a type declares its own of is counted under the first name alone.
    @Test
    func aLineWritingTwoShadowedAliasesInATypeIsCountedOnce() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            extension Space {
                static func make() { _ = (Crate("a"), Bin("b")) }
            }
            """
        )

        #expect(Self.holdsClause(Self.typeClause("Bin"), in: output), "\(output)")
        #expect(!output.contains("writing \"Crate\" bare"), "\(output)")
    }

    /// A line writing two aliases a function declares its own of is counted under the first name alone.
    @Test
    func aLineWritingTwoShadowedAliasesInAFunctionIsCountedOnce() async throws {
        let output = try await Self.lookup(
            declaring: Self.base,
            calling: """
            struct Shop {
                func make() {
                    struct Crate {
                        init(_ s: String) {}
                    }
                    struct Bin {
                        init(_ s: String) {}
                    }
                    _ = (Crate("a"), Bin("b"))
                }
            }
            """
        )

        #expect(Self.holdsClause(Self.functionClause("Bin"), in: output), "\(output)")
        #expect(!output.contains("writing \"Crate\" bare"), "\(output)")
    }

    /// Two lines, each writing one of the names, are counted under one clause each.
    @Test
    func separateLinesEachKeepTheirOwnClause() async throws {
        let output = try await Self.lookup(
            declaring: Self.base + "\n" + Self.space,
            calling: """
            extension Space {
                static func make() {
                    _ = Crate("a")
                    _ = Bin("b")
                }
            }
            """
        )

        #expect(Self.holdsClause(Self.typeClause("Bin"), in: output), "\(output)")
        #expect(Self.holdsClause(Self.typeClause("Crate"), in: output), "\(output)")
    }
}
