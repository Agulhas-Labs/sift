//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query keeps a site written on a tree type's name where the extended type's generic parameter, or an attached macro on a type around the site or on the receiver, may give the name another meaning.
///
/// The constrained-extension fixture typechecks with swiftc as module App; the macro fixture is reasoned, since `@Stocked` and `@Forwarded` stand for a dependency's member and extension macros.
@Suite(.temporaryDirectories)
struct WhereConstrainedScopeNameTests {
    private static var constrained: String {
        """
        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        struct Element { let key: String }
        struct Item { let key: String }
        extension Array where Element == Depot {
            var constrained: Int { Element().stock }
        }
        struct Box<Item> { let item: Item }
        extension Box where Item == Depot {
            var boxed: Int { Item().stock }
        }
        extension Box<Depot> {
            var specialised: Int { Item().stock }
        }
        extension Array where Element == Spare {
            var spared: Int { Spare().stock }
        }
        @globalActor actor Lane { static let shared = Lane() }
        @Lane struct Quiet {
            var lane: Int { Spare().stock }
        }
        @MainActor struct Calm {
            var main: Int { Spare().stock }
        }
        """
    }

    private static var clauseForms: String {
        """
        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        struct Element { let key: String }
        extension Array where Self.Element == Depot {
            var qualified: Int { Element().stock }
        }
        extension Array where Depot == Element {
            var flipped: Int { Element().stock }
        }
        extension Array where Spare == Element {
            var swapped: Int { Spare().stock }
        }
        extension Array {
            func total() -> Int where Element == Depot { Element().stock }
            func spare() -> Int where Element == Spare { Spare().stock }
        }
        """
    }

    private static var macros: String {
        """
        import Kit

        struct Depot { var stock = 0 }
        struct Bin { let key: String }
        @Stocked struct Row {
            var held: Int { Bin().stock }
        }
        @Forwarded struct Crate {}
        struct Use {
            var crated: Int { Crate().stock }
        }
        """
    }

    private static var implemented: String {
        """
        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        class Gizmo {}
        @objc @implementation extension Gizmo {
            var made: Int { Spare().stock }
        }
        """
    }

    private static func answer(_ source: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
    }

    /// A name an extension's where clause constrains, or the extended tree type's generic parameter, is that parameter rather than the top-level type of the name; the type written on the right of the clause, and a type under a global actor, are still the tree's.
    @Test
    func aGenericParameterOfTheExtendedTypeIsKept() async throws {
        let output = try await Self.answer(Self.constrained)

        #expect(output.contains("3 on other types dropped"), "\(output)")
        for member in ["Array.constrained", "Box.boxed", "Box<Depot>.specialised"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
        for member in ["Array.spared", "Quiet.lane", "Calm.main"] {
            #expect(!output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// A where clause names the extended type's parameter behind `Self.`, on the right of a same-type requirement, or in a function's own clause, and each is that parameter; the concrete type on the other side is still the tree's.
    @Test
    func aParameterAnyWhereClauseFormConstrainsIsKept() async throws {
        let output = try await Self.answer(Self.clauseForms)

        #expect(output.contains("2 on other types dropped"), "\(output)")
        for member in ["Array.qualified", "Array.flipped", "Array.total()"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
        for member in ["Array.swapped", "Array.spare()"] {
            #expect(!output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// `@implementation`, which the language defines for an extension implementing an Objective-C class, is no macro, so a site inside the extension is still another type's.
    @Test
    func anObjectiveCImplementationIsNoMacro() async throws {
        let output = try await Self.answer(Self.implemented)

        #expect(output.contains("1 on other types dropped"), "\(output)")
        #expect(!output.contains("in Gizmo.made"), "\(output)")
    }

    /// An attached macro the tree does not declare may add a typealias of the name to the type around the site, or a dynamic member to the receiver's type, so both sites stay listed.
    @Test
    func aNameAMacroMayReshapeIsKept() async throws {
        let output = try await Self.answer(Self.macros)

        #expect(output.contains("on types outside the tree"), "\(output)")
        for member in ["Row.held", "Use.crated"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }
}
