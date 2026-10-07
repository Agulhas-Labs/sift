//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified query keeps a site written on a tree type's name where a supertype the tree does not declare, of a type around the site, may supply that name ahead of the tree's type: a superclass or a dependency's protocol any name, and a framework protocol only the names it is known to supply.
///
/// Each fixture typechecks with swiftc as module App against a module Kit holding `open class Holder<Value>`, with a `Current` property and `Item` and `Bin` typealiases standing for `Value`, and `protocol Forwarding`, with an associated type `Bin` returned by `make()`.
@Suite(.temporaryDirectories)
struct WhereEnclosingSupertypeNameTests {
    private static var supplied: String {
        """
        import Kit

        struct Depot { var stock = 0 }
        struct Current { let key: String }
        struct Item { let key: String }
        struct Element { let key: String }
        struct Bin { let key: String }
        final class Crate: Holder<Depot> {
            init() { super.init(Depot()) }
            var cur: Int { Current.stock }
            var item: Int { Item().stock }
        }
        struct Shelf: Sequence {
            func makeIterator() -> IndexingIterator<[Depot]> { [Depot()].makeIterator() }
            var built: Int { Element().stock }
        }
        struct Row: Forwarding {
            func make() -> Depot { Depot() }
            var forwarded: Int { Bin().stock }
        }
        final class Shed: Holder<Depot> {
            init() { super.init(Depot()) }
            var held: Int { Bin().stock }
        }
        """
    }

    private static var notSupplied: String {
        """
        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        struct Tidy: Equatable, Codable {
            var counted: Int { Spare().stock }
        }
        struct Listing: Sequence {
            func makeIterator() -> IndexingIterator<[Spare]> { [Spare()].makeIterator() }
            var spared: Int { Spare().stock }
        }
        """
    }

    private static var extended: String {
        """
        import Kit

        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        struct Item { let key: String }
        struct Element { let key: String }
        extension Holder where Value == Depot {
            var held: Int { Item().stock }
        }
        extension Sequence where Self == [Depot] {
            var pinned: Int { Element().stock }
        }
        struct Box<Item> { let item: Item }
        typealias DepotBox = Box<Depot>
        extension DepotBox {
            var aliased: Int { Item().stock }
        }
        typealias Depots = [Depot]
        extension Depots {
            var listed: Int { Element().stock }
        }
        typealias KitHolder = Holder<Depot>
        extension KitHolder {
            var kept: Int { Item().stock }
        }
        extension Array {
            var spared: Int { Spare().stock }
        }
        """
    }

    private static var local: String {
        """
        import Kit

        struct Depot { var stock = 0 }
        struct Element { let key: String }
        struct Item { let key: String }
        struct Lined: Equatable { let key: String }
        func outer() -> Int {
            struct Lined: Sequence {
                func makeIterator() -> IndexingIterator<[Depot]> { [Depot()].makeIterator() }
                var built: Int { Element().stock }
            }
            final class Held: Holder<Depot> {
                init() { super.init(Depot()) }
                var item: Int { Item().stock }
            }
            return Lined().built + Held().item
        }
        """
    }

    private static var rawAndMarkers: String {
        """
        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        enum Kind: String, CaseIterable {
            case first
            var named: Int { Spare().stock }
        }
        enum Level: Int {
            case low
            var ranked: Int { Spare().stock }
        }
        struct Gizmo: BitwiseCopyable, CustomDebugStringConvertible {
            var debugDescription: String { "" }
            var marked: Int { Spare().stock }
        }
        struct Orchard: ~Copyable {
            var unique: Int { Spare().stock }
        }
        protocol Shelving: AnyObject {}
        extension Shelving {
            var shelved: Int { Spare().stock }
        }
        extension String {
            var spare: Int { Spare().stock }
        }
        typealias Words = String
        extension Words {
            var worded: Int { Spare().stock }
        }
        """
    }

    private static var nestedTwin: String {
        """
        import UIKit

        struct Depot { var stock = 0 }
        struct Spare { var stock = 1 }
        enum Theme {
            struct Label {
                var themed: Int { Spare().stock }
            }
        }
        extension UIView {
            var viewed: Int { Spare().stock }
        }
        extension Label {
            var labelled: Int { Spare().stock }
        }
        extension Theme.Label {
            var dotted: Int { Spare().stock }
        }
        """
    }

    private static func answer(_ source: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.stock", in: root)
    }

    /// A dependency superclass's property or typealias, an inferred `Sequence` element type, and a dependency protocol's associated type may each be what a name written inside the type means, so the site stays listed and is counted outside the tree.
    @Test
    func aNameASupertypeOutsideTheTreeMaySupplyIsKept() async throws {
        let output = try await Self.answer(Self.supplied)

        #expect(output.contains("on types outside the tree"), "\(output)")
        for member in ["Crate.cur", "Crate.item", "Shelf.built", "Row.forwarded", "Shed.held"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// An extended type the tree does not declare, or declares only as a typealias, may supply the name as a supertype outside the tree does: a dependency class's typealias, a protocol's associated type, or the generic parameter of the type an alias stands for; `Array` supplies no `Spare`.
    @Test
    func aNameAnExtendedTypeOutsideTheTreeMaySupplyIsKept() async throws {
        let output = try await Self.answer(Self.extended)

        #expect(!output.contains("in Array.spared"), "\(output)")
        #expect(output.contains("1 on other types dropped"), "\(output)")
        for member in ["Holder.held", "Sequence.pinned", "DepotBox.aliased", "Depots.listed", "KitHolder.kept"] {
            #expect(output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// A type declared inside a function has supertypes the tree's top-level declarations cannot show, even where a top-level type shares its name and conforms only to `Equatable`, so a name written inside it is kept.
    @Test
    func aNameInsideAFunctionLocalTypeIsKept() async throws {
        let output = try await Self.answer(Self.local)

        #expect(!output.contains("dropped"), "\(output)")
        #expect(output.contains("Element().stock"), "\(output)")
        #expect(output.contains("Item().stock"), "\(output)")
    }

    /// An enum's raw type supplies only `RawValue`, and `AnyObject`, `BitwiseCopyable`, `CustomDebugStringConvertible` and `~Copyable` supply no name, so `Spare` inside them is the tree's; inside `extension String`, or an extension of a typealias for it, the extended type itself may still supply any name.
    @Test
    func aRawTypeOrAMarkerSuppliesNoOtherName() async throws {
        let output = try await Self.answer(Self.rawAndMarkers)

        #expect(output.contains("5 on other types dropped"), "\(output)")
        #expect(output.contains("in String.spare"), "\(output)")
        #expect(output.contains("in Words.worded"), "\(output)")
        for member in ["Kind.named", "Level.ranked", "Gizmo.marked", "Orchard.unique", "Shelving.shelved"] {
            #expect(!output.contains("in \(member)"), "\(member)\n\(output)")
        }
    }

    /// A protocol that supplies no type name, or none of the name written, leaves the tree's type of the name the one the site means.
    @Test
    func aNameNoSupertypeSuppliesIsAnotherTypes() async throws {
        let output = try await Self.answer(Self.notSupplied)

        #expect(!output.contains("in Tidy.counted"), "\(output)")
        #expect(!output.contains("in Listing.spared"), "\(output)")
        #expect(output.contains("2 on other types dropped"), "\(output)")
    }

    /// An extension written with the bare name of a type the tree declares only inside another type extends a framework type, which may supply any name as an extended type the tree does not declare at all does; inside the nested type itself, or an extension of it written `Theme.Label`, the tree's `Spare` is still meant.
    @Test
    func aNameAnExtensionOfANestedTypesNameMaySupplyIsKept() async throws {
        let output = try await Self.answer(Self.nestedTwin)

        #expect(output.contains("on types outside the tree"), "\(output)")
        #expect(output.contains("in UIView.viewed"), "\(output)")
        #expect(output.contains("in Label.labelled"), "\(output)")
        #expect(!output.contains("in Theme.Label.themed"), "\(output)")
        #expect(!output.contains("in Theme.Label.dotted"), "\(output)")
        #expect(output.contains("2 on other types dropped"), "\(output)")
    }
}
