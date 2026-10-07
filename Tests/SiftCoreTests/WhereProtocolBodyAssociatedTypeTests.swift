//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a type's name written bare in the body of a protocol that declares an associated type of the name, which Swift reads as that associated type: the line is counted apart only where the protocol's own body declares it outside any `#if`, and stays a use wherever else the associated type comes from.
///
/// Every fixture typechecks with `swiftc`, and its last line uses the type asked for.
@Suite(.temporaryDirectories)
struct WhereProtocolBodyAssociatedTypeTests {
    /// `take`'s `Item` is `Holder`'s associated type, counted apart beside the line in `Plain`, which declares its own.
    @Test
    func aBareNameInAProtocolDeclaringTheAssociatedTypeIsCountedApart() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer(
            "Search.Item",
            source: "enum Search { struct Item { func searched() {} } }\nprotocol Holder {\n    associatedtype Item\n    func take(_ x: Item)\n}\nstruct Plain {\n    func use(_ x: Item) {}\n    struct Item {}\n}\nfunc check() { Search.Item().searched() }\n"
        )

        #expect(!search.contains("\n    :4  | func take(_ x: Item)"), "\(search)")
        #expect(search.contains("; 2 more lines writing \"Item\" bare inside a type that declares its own \"Item\""), "\(search)")
        #expect(search.contains("\n    :10  | func check() { Search.Item().searched() }"), "\(search)")
    }

    /// A top-level `Item` is no more what `take` writes than a nested one.
    @Test
    func aTopLevelTypeOfTheNameIsNotWhatTheProtocolBodyWrites() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer(
            "Sources.Item",
            source: "struct Item { func used() {} }\nprotocol Holder {\n    associatedtype Item\n    func take(_ x: Item)\n}\nfunc check() { Item().used() }\n"
        )

        #expect(!item.contains("\n    :4  | func take(_ x: Item)"), "\(item)")
        #expect(item.contains("; 1 more line writing \"Item\" bare inside a type that declares its own \"Item\""), "\(item)")
    }

    /// Declared under `#if`, the associated type may not exist in the build, where `Item` is the top-level type, so the line stays a use.
    @Test
    func anAssociatedTypeUnderIfConfigKeepsTheLine() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer(
            "Sources.Item",
            source: "struct Item { func used() {} }\nprotocol Holder {\n    #if DEBUG\n    associatedtype Item\n    #endif\n    func take(_ x: Item)\n}\nfunc check() { Item().used() }\n"
        )

        #expect(item.contains("\n    :6  | func take(_ x: Item)"), "\(item)")
        #expect(!item.contains("bare inside a type that declares its own"), "\(item)")
    }

    /// An associated type `Sub` inherits from `Holder` is not declared in `Sub`'s own body, so the line in it stays a use.
    @Test
    func anInheritedAssociatedTypeKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer(
            "Search.Item",
            source: "enum Search { struct Item { func searched() {} } }\nprotocol Holder { associatedtype Item }\nprotocol Sub: Holder { func f(_ x: Item) }\nfunc check() { Search.Item().searched() }\n"
        )

        #expect(search.contains("\n    :3  | protocol Sub: Holder { func f(_ x: Item) }"), "\(search)")
        #expect(!search.contains("bare inside a type that declares its own"), "\(search)")
    }

    /// An extension of the protocol is not its body, so the line in it stays a use while the body's own line is counted apart.
    @Test
    func aProtocolExtensionKeepsTheLine() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer(
            "Search.Item",
            source: "enum Search { struct Item { func searched() {} } }\nprotocol Holder {\n    associatedtype Item\n    func take(_ x: Item)\n}\nextension Holder { func give(_ x: Item) { take(x) } }\nfunc check() { Search.Item().searched() }\n"
        )

        #expect(search.contains("\n    :6  | extension Holder { func give(_ x: Item) { take(x) } }"), "\(search)")
        #expect(!search.contains("\n    :4  | func take(_ x: Item)"), "\(search)")
    }

    /// Asked for the associated type itself, the protocol body's line is its use, never set apart.
    @Test
    func askingForTheAssociatedTypeKeepsTheLine() async throws {
        let holder = try await WhereQualifiedProtocolNoteTests.answer(
            "Holder.Item",
            source: "enum Search { struct Item { func searched() {} } }\nprotocol Holder {\n    associatedtype Item\n    func take(_ x: Item)\n}\nfunc check() { Search.Item().searched() }\n"
        )

        #expect(holder.contains("\n    :4  | func take(_ x: Item)"), "\(holder)")
        #expect(!holder.contains("bare inside a type that declares its own"), "\(holder)")
    }

    /// A custom attribute names the module-scoped type, so `@Item` is a use of the global actor and the line stays listed.
    ///
    /// swiftc warns "ignoring associated type 'Item' in favor of module-scoped property wrapper 'Item'".
    @Test
    func aGlobalActorAttributeInTheProtocolBodyKeepsTheLine() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer(
            "Sources.Item",
            source: "@globalActor actor Item { static let shared = Item() }\nprotocol Holder {\n    associatedtype Item\n    @Item func f()\n}\nfunc check() { _ = Item.shared }\n"
        )

        #expect(item.contains("\n    :4  | @Item func f()"), "\(item)")
        #expect(!item.contains("bare inside a type that declares its own"), "\(item)")
    }

    /// The same for a result builder, whose attribute names the module-scoped type.
    @Test
    func aResultBuilderAttributeInTheProtocolBodyKeepsTheLine() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer(
            "Sources.Item",
            source: "@resultBuilder enum Item { static func buildBlock(_ x: Int) -> Int { x } }\nprotocol Holder {\n    associatedtype Item\n    @Item var body: Int { get }\n}\nfunc check() { _ = Item.buildBlock(1) }\n"
        )

        #expect(item.contains("\n    :4  | @Item var body: Int { get }"), "\(item)")
        #expect(!item.contains("bare inside a type that declares its own"), "\(item)")
    }
}
