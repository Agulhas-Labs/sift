//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An operator is used by its symbol — `a <~> b`, `-a`, `b^^`, or handed on bare as `reduce(x, +)` — never as `name(`, so the scan by written name lists those uses rather than saying no call is spelled.
@Suite(.temporaryDirectories)
struct WhereOperatorUseTests {
    static var declaring: (path: String, source: String) {
        (
            path: "Sources/GizmoCore/Vault.swift",
            source: """
            infix operator <~>: AdditionPrecedence
            postfix operator ^^

            struct Vault {
                var weight: Int
                static func + (lhs: Vault, rhs: Vault) -> Vault { Vault(weight: lhs.weight) }
                static prefix func - (vault: Vault) -> Vault { vault }
            }

            func <~> (lhs: Vault, rhs: Vault) -> Int { lhs.weight }
            postfix func ^^ (vault: Vault) -> Vault { vault }
            """
        )
    }

    static var using: (path: String, source: String) {
        (
            path: "Sources/GizmoCore/Depot.swift",
            source: """
            func stock(_ vault: Vault) -> Int {
                let sum = vault + vault
                let flipped = -vault
                let squared = vault^^
                let all = [vault].reduce(vault, +)
                return (sum <~> flipped) + squared.weight + all.weight
            }
            """
        )
    }

    static func answer(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for file in [declaring, using] {
            try TestSources.write(file.source, to: file.path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// An infix operator's uses are listed, the operator declaration's with them, and a bare `+` handed on is one of them.
    @Test
    func anInfixOperatorsUsesAreListedByItsSymbol() async throws {
        let custom = try await Self.answer("<~>")
        #expect(!custom.contains("no call spelled"), "\(custom)")
        #expect(custom.contains("    :6  in stock(_:)  | return (sum <~> flipped) + squared.weight + all.weight"), "\(custom)")

        let plus = try await Self.answer("Vault.+")
        #expect(!plus.contains("no call spelled"), "\(plus)")
        #expect(plus.contains("    :2  in stock(_:).sum  | let sum = vault + vault"), "\(plus)")
        #expect(plus.contains("    :5  in stock(_:).all  | let all = [vault].reduce(vault, +)"), "\(plus)")
    }

    /// A prefix and a postfix operator are found where they are applied.
    @Test
    func prefixAndPostfixOperatorsAreListedWhereApplied() async throws {
        let prefix = try await Self.answer("Vault.-")
        #expect(prefix.contains("    :3  in stock(_:).flipped  | let flipped = -vault"), "\(prefix)")

        let postfix = try await Self.answer("^^")
        #expect(!postfix.contains("no call spelled"), "\(postfix)")
        #expect(postfix.contains("    :4  in stock(_:).squared  | let squared = vault^^"), "\(postfix)")
    }
}
