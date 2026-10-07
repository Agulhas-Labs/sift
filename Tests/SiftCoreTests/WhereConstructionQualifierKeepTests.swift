//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a construction whose qualifier the index reads, with no index store, as another type's owner or as declaring no type of the name: the initializer's fallback, a type with no init of its own and a memberwise label call each keep it, listed and noted, since reading a qualifier from the index alone is not sound.
///
/// Every fixture typechecks with `swiftc`, and its last line calls a member only the asked type has, so Swift's own reading of the call is the asked type.
@Suite(.temporaryDirectories)
struct WhereConstructionQualifierKeepTests {
    private static func answer(_ symbol: String, source: String, references: Bool = false) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "a construction behind a qualifier the index misreads")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: references))
    }

    /// `Sub.Item` is the typealias `Sub` declares, which Swift finds before the struct nested in its superclass; `item` is what the fixture's members differ by.
    private static func supertype(item: String, call: String) -> String {
        "enum Search { struct Item { \(item)func searched() {} } }\nclass Base { struct Item {} }\nclass Sub: Base { typealias Item = Search.Item }\nfunc build() { \(call).searched() }\n"
    }

    private static var readAsBase: String {
        "1 of them writes \"Item\" behind a qualifier the index reads as Base, which declares another \"Item\", so may be that type's rather than this struct's — counted all the same, as a qualifier read from the index alone may name another type in Swift"
    }

    /// The fallback over a declared initializer keeps the call and notes it beside the count by name.
    @Test
    func theInitializersFallbackKeepsACallReadAsASupertypesType() async throws {
        let output = try await Self.answer("Search.Item.init", source: Self.supertype(item: "init() {}; ", call: "Sub.Item()"))

        #expect(output.contains("\"Item.init\" (1 call site by name, \(Self.readAsBase), in 1 file):"), "\(output)")
        #expect(output.contains("\n    :4  in build()  | func build() { Sub.Item().searched() }"), "\(output)")
        #expect(!output.contains("dropped"), "\(output)")
    }

    /// A type that declares no init keeps the call and notes it beside the count by name.
    @Test
    func aTypeWithNoInitKeepsACallReadAsASupertypesType() async throws {
        let output = try await Self.answer("Search.Item.init", source: Self.supertype(item: "", call: "Sub.Item()"))

        #expect(output.contains("\"Item.init\" (1 call site by name, \(Self.readAsBase), in 1 file):"), "\(output)")
        #expect(output.contains("\n    :4  in build()  | func build() { Sub.Item().searched() }"), "\(output)")
        #expect(!output.contains("dropped"), "\(output)")
    }

    /// A call passing the stored property's label is listed with the property's uses and flagged with the owner the index reads.
    @Test
    func aMemberwiseLabelCallReadAsASupertypesTypeIsListedAndFlagged() async throws {
        let output = try await Self.answer("Search.Item.weight", source: Self.supertype(item: "var weight: Int; ", call: "Sub.Item(weight: 1)"), references: true)

        #expect(output.contains("1 call writing weight: to Item(…) that may build another type named Item, flagged"), "\(output)")
        #expect(output.contains(":4  in build() (behind a qualifier the index reads as Base, which declares another Item)  | func build() { Sub.Item(weight: 1).searched() }"), "\(output)")
        #expect(!output.contains("dropped"), "\(output)")
    }

    /// `Box.Item` is the associated type `Box`'s conformance infers, which the index holds no typealias for, so it reads `Box` as declaring no `Item`.
    @Test
    func anInferredAssociatedTypeKeepsTheCall() async throws {
        let source = "enum Search { struct Item { init() {}; func searched() {} } }\nprotocol Shelf { associatedtype Item; func make(_: Item) }\nstruct Box: Shelf { func make(_: Search.Item) {} }\nfunc build() { Box.Item().searched() }\n"
        let output = try await Self.answer("Search.Item.init", source: source)

        #expect(output.contains("\"Item.init\" (1 call site by name, 1 of them writes \"Item\" behind a qualifier the index reads as Box, which declares no \"Item\", so may call no Item.init — counted all the same, as a qualifier read from the index alone may name another type in Swift, in 1 file):"), "\(output)")
        #expect(output.contains("\n    :4  in build()  | func build() { Box.Item().searched() }"), "\(output)")
        #expect(!output.contains("calling no Item.init dropped"), "\(output)")
    }

    /// The same inference on a type with no init of its own: the call is kept and noted.
    @Test
    func anInferredAssociatedTypeKeepsTheCallOfATypeWithNoInit() async throws {
        let source = "enum Search { struct Item { func searched() {} } }\nprotocol Shelf { associatedtype Item; func make(_: Item) }\nstruct Box: Shelf { func make(_: Search.Item) {} }\nfunc build() { Box.Item().searched() }\n"
        let output = try await Self.answer("Search.Item.init", source: source)

        #expect(output.contains("behind a qualifier the index reads as Box, which declares no \"Item\", so may call no Item.init"), "\(output)")
        #expect(output.contains("\n    :4  in build()  | func build() { Box.Item().searched() }"), "\(output)")
        #expect(!output.contains("dropped"), "\(output)")
    }
}
