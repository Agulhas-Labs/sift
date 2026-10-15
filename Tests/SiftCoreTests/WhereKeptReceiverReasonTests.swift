//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified member query asked with no store counts the sites it keeps on an unproven receiver by why each was kept, so a tree type is never counted as one the tree does not declare.
@Suite(.temporaryDirectories)
struct WhereKeptReceiverReasonTests {
    private static func answer(_ calls: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (line: String, output: String) {
        let source = """
        import SwiftUI

        struct Depot {
            static func load(_ count: Int) {}
        }
        enum Spare: Equatable {
            case one
            static func load(_ count: Int) {}
        }
        #if DEBUG
        struct Crate {
            static func load(_ count: Int) {}
        }
        #endif
        struct Orchard {
            func uses() {
        \(calls)
            }
        }
        """
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let output = try await CallSiteHeadingTests.lookup("Depot.load", in: root)
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("\"load\" (") }, sourceLocation: sourceLocation)
        return (String(line), output)
    }

    /// A site on a tree type that conforms to `Equatable` and declares a static member of the name is kept, since a supertype outside the tree may hand the member on, and counted as a tree type, not as one the tree does not declare.
    @Test
    func aTreeTypeWithASupertypeOutsideTheTreeIsCountedAsATreeType() async throws {
        let (line, output) = try await Self.answer("        Spare.load(1)")

        #expect(output.contains("Spare.load(1)"), "\(output)")
        #expect(line.contains("1 on tree types a supertype outside the tree may hand it on (Spare ×1)"), "\(line)")
        #expect(!line.contains("types the tree does not declare"), "\(line)")
    }

    /// A site on a type the tree does not declare, which a framework may give the member, is kept and counted as such.
    @Test
    func aReceiverTheTreeDoesNotDeclareIsCountedAsUndeclared() async throws {
        let (line, output) = try await Self.answer("        Binding<Int>.load(2)")

        #expect(output.contains("Binding<Int>.load(2)"), "\(output)")
        #expect(line.contains("1 on types the tree does not declare (Binding ×1)"), "\(line)")
    }

    /// A tree type declared only under an `#if` is out of the site's sight, so the site is kept and counted as on a tree type out of sight.
    @Test
    func aTreeTypeOutOfSightIsCountedAsOutOfSight() async throws {
        let (line, output) = try await Self.answer("        Crate.load(3)")

        #expect(output.contains("Crate.load(3)"), "\(output)")
        #expect(line.contains("1 on tree types out of the site's sight (Crate ×1)"), "\(line)")
        #expect(!line.contains("types the tree does not declare"), "\(line)")
    }

    /// Sites kept for different reasons get one clause each, in a fixed order, with the total kept unchanged.
    @Test
    func eachReasonGetsItsOwnClause() async throws {
        let (line, output) = try await Self.answer("        Spare.load(1)\n        Binding<Int>.load(2)\n        Binding<Int>.load(4)\n        Crate.load(3)")

        #expect(line.contains("2 on types the tree does not declare (Binding ×2), 1 on tree types out of the site's sight (Crate ×1), 1 on tree types a supertype outside the tree may hand it on (Spare ×1)"), "\(line)")
        for call in ["Spare.load(1)", "Binding<Int>.load(2)", "Binding<Int>.load(4)", "Crate.load(3)"] {
            #expect(output.contains(call), "\(output)")
        }
    }
}
