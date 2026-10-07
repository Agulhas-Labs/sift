//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a type's bare name written inside a function that declares a struct, class, enum or actor of the name: Swift finds the local one first, throughout the braces it is declared in, so with no store the line is counted apart; wherever the local declaration may be another name for the asked type, or Swift may search something else first, the line stays a use.
///
/// Every fixture typechecks with `swiftc -parse-as-library -module-name Lib -swift-version 6`, and each line, kept or set apart, calls a member only the type it means has, or the fixture's last line does.
@Suite(.temporaryDirectories)
struct WhereLocalTypeShadowTests {
    /// The words the clause counting a line set apart by a local declaration carries.
    private static var setApart: String {
        "bare inside a function that declares its own"
    }

    /// A local struct is what `Log` means throughout its function, on the line before its declaration as on the line after.
    @Test
    func aLocalStructSetsApartTheLinesOfItsFunction() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc probe() {\n    Log.local()\n    struct Log { static func local() {} }\n    Log.local()\n}\nfunc check() { Log.top() }\n")

        #expect(log.contains("\"Log\" used by 1 line in 1 file — "), "\(log)")
        #expect(log.contains("; 2 more lines writing \"Log\" bare inside a function that declares its own \"Log\", which is what the name means there, so not use"), "\(log)")
        #expect(log.contains("\n    :7  | func check() { Log.top() }"), "\(log)")
        #expect(!log.contains(":3  |"), "\(log)")
    }

    /// A local struct is what `Log` means in the closure and the function nested in its function too.
    @Test
    func aLocalStructSetsApartNestedBodiesToo() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc probe() {\n    struct Log { var count = 0 }\n    let tally = Log()\n    let show = { (x: Log) in x.count }\n    func nested(_ x: Log) -> Int { x.count }\n    _ = show(tally) + nested(tally)\n}\nfunc check() { Log.top() }\n")

        #expect(log.contains("\"Log\" used by 1 line in 1 file — "), "\(log)")
        #expect(log.contains("; 3 more lines writing \"Log\" bare inside a function that declares its own \"Log\""), "\(log)")
    }

    /// A local struct shadows a member type of the type around the method declaring it, and only inside the method.
    @Test
    func aLocalStructShadowsAMemberTypeInsideItsMethod() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer("Holder.Item", source: "struct Holder {\n    struct Item { func held() {} }\n    func make() {\n        struct Item { func mine() {} }\n        let x = Item()\n        x.mine()\n    }\n    func take(_ y: Item) { y.held() }\n}\n")

        #expect(item.contains("\"Item\" used by 1 line in 1 file — "), "\(item)")
        #expect(item.contains("; 1 more line writing \"Item\" bare inside a function that declares its own \"Item\""), "\(item)")
        #expect(item.contains("\n    :8  | func take(_ y: Item) { y.held() }"), "\(item)")
    }

    /// A local typealias may name anything, here a dictionary, but the scan cannot prove what: every line stays a use.
    @Test
    func aLocalTypealiasKeepsTheLines() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc probe() {\n    typealias Log = [String: Int]\n    let tally: Log = [:]\n    let show = { (x: Log) in x.count }\n    func nested(_ x: Log) -> Int { x.count }\n    _ = show(tally) + nested(tally)\n}\n")

        #expect(log.contains("\n    :4  | let tally: Log = [:]"), "\(log)")
        #expect(log.contains("\n    :6  | func nested(_ x: Log) -> Int { x.count }"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// `Journal` is a typealias of the asked `Log`, so the local `Log` written through it is the asked type.
    @Test
    func aLocalTypealiasThroughATypealiasOfTheTypeKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\ntypealias Journal = Log\nfunc probe() {\n    typealias Log = Journal\n    Log.top()\n}\n")

        #expect(log.contains("\n    :5  | Log.top()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A local typealias writing the asked name is the asked type.
    @Test
    func aLocalTypealiasWritingTheNameKeepsTheLine() async throws {
        let item = try await WhereQualifiedProtocolNoteTests.answer("Search.Item", source: "enum Search { struct Item { func searched() {} } }\nfunc probe() {\n    typealias Item = Search.Item\n    let x: Item? = nil\n    x?.searched()\n}\n")

        #expect(item.contains("\n    :4  | let x: Item? = nil"), "\(item)")
        #expect(!item.contains(Self.setApart), "\(item)")
    }

    /// `Kept` is declared inside a function, where the index cannot see what it names: here the asked `Log`.
    @Test
    func aLocalTypealiasThroughAnotherLocalNameKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc outer() {\n    typealias Kept = Log\n    func probe() {\n        typealias Log = Kept\n        Log.top()\n    }\n    probe()\n}\n")

        #expect(log.contains("\n    :6  | Log.top()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// `Element` is `Collection`'s associated type, which the where clause makes the asked `Log`.
    @Test
    func aLocalTypealiasOfAnAssociatedTypeKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { func top() {} }\nextension Collection where Element == Log {\n    func probe() {\n        typealias Log = Element\n        _ = first.map { (x: Log) in x.top() }\n    }\n}\n")

        #expect(log.contains("\n    :5  | _ = first.map { (x: Log) in x.top() }"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// The extension is of the standard `Array`, not `Shapes.Array`, whose `Element` is the asked `Log`.
    @Test
    func aLocalTypealiasOfAnExtendedTypesParameterKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { case a; func top() {} }\nenum Shapes { struct Array {} }\nextension Array<Log> {\n    func probe() {\n        typealias Log = Element\n        let x: Log = .a\n        x.top()\n    }\n}\n")

        #expect(log.contains("\n    :6  | let x: Log = .a"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// `Shelf.Element` is `Sequence`'s, inferred from `makeIterator` as the asked `Log`.
    @Test
    func aLocalTypealiasOfAnInferredMemberKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { case a; func top() {} }\nstruct Shelf: Sequence {\n    func makeIterator() -> IndexingIterator<[Log]> { [Log.a].makeIterator() }\n}\nfunc probe() {\n    typealias Log = Shelf.Element\n    let x: Log = .a\n    x.top()\n}\n")

        #expect(log.contains("\n    :7  | let x: Log = .a"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A local struct inside an `#if` clause is not compiled in every build, and where it is not, `Log` is the asked type.
    @Test
    func aLocalTypeInsideAnIfConfigKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc probe() {\n    #if DEBUG\n    struct Log {}\n    #endif\n    Log.top()\n}\n")

        #expect(log.contains("\n    :6  | Log.top()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// Inside `Sub`, Swift finds its superclass's `Log` before the function's own.
    @Test
    func aTypeBetweenTheLineAndTheLocalDeclarationKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Base.Log", source: "class Base { struct Log { func based() {} } }\nfunc probe() {\n    struct Log {}\n    class Sub: Base { func take(_ x: Log) { x.based() } }\n}\n")

        #expect(log.contains("\n    :4  | class Sub: Base { func take(_ x: Log) { x.based() } }"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A local struct in another function, or in a block the line is not in, does not reach the line.
    @Test
    func aLocalTypeOutOfTheLinesScopeKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc other() { struct Log {} }\nfunc probe() {\n    if true { struct Log {} }\n    Log.top()\n}\n")

        #expect(log.contains("\n    :5  | Log.top()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A function's signature is read outside its body, so the body's struct does not reach it.
    @Test
    func theFunctionsOwnSignatureKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { func top() {} }\nfunc probe(_ x: Log) {\n    struct Log {}\n    x.top()\n}\n")

        #expect(log.contains("\n    :2  | func probe(_ x: Log) {"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A value of the name nearer the line, here the asked type's metatype through a typealias, is what an expression writing it means.
    @Test
    func aValueOfTheNameKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\ntypealias Journal = Log\nfunc probe() {\n    struct Log {}\n    do {\n        let Log = Journal.self\n        Log.top()\n    }\n}\n")

        #expect(log.contains("\n    :7  | Log.top()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A custom attribute in the body may be a macro declaring the name, so the line stays a use, though here it is a property wrapper.
    @Test
    func aCustomAttributeInTheBodyKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "@propertyWrapper struct Wrap { var wrappedValue: Int }\nenum Log { static func top() {} }\nfunc probe() {\n    struct Log { static func local() {} }\n    @Wrap var y = 1\n    Log.local()\n    _ = y\n}\n")

        #expect(log.contains("\n    :6  | Log.local()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }

    /// A freestanding expansion in the body may declare the name, so the line stays a use, though here it is `#warning`.
    @Test
    func aFreestandingExpansionInTheBodyKeepsTheLine() async throws {
        let log = try await WhereQualifiedProtocolNoteTests.answer("Log", source: "enum Log { static func top() {} }\nfunc probe() {\n    struct Log { static func local() {} }\n    #warning(\"probe\")\n    Log.local()\n}\n")

        #expect(log.contains("\n    :5  | Log.local()"), "\(log)")
        #expect(!log.contains(Self.setApart), "\(log)")
    }
}
