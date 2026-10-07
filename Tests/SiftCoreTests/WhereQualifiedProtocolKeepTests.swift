//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers qualified lines Swift reads as the asked protocol where the index could read them as another type of the name — through a typealias, a supertype, a nested type, a generic or local parameter, another module: each stays listed, counted and a conformer, and is noted only where its qualifier spells the other type's owner.
@Suite(.temporaryDirectories)
struct WhereQualifiedProtocolKeepTests {
    /// The note's opening, said only where some kept line writes the name behind another owner's qualifier.
    private static var noted: String {
        "only behind"
    }

    /// How a conformer row marked for its clause's spelling ends.
    private static var marked: String {
        "(clause writes"
    }

    /// `Sub.Answer` is `Sub`'s own typealias of `Search.Answer`, and `Sub` owns no other `Answer`, so the lines are kept and nothing is noted.
    @Test
    func aTypealiasThroughASubclassIsKeptUnnoted() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nclass Base { protocol Answer {} }\nclass Sub: Base { typealias Answer = Search.Answer }\nstruct U: Sub.Answer {}\nfunc probe(_ x: any Sub.Answer) {}\n")

        #expect(search.contains("\"Answer\" used by 2 lines in 1 file — "), "\(search)")
        #expect(search.contains("\n    :4  | struct U: Sub.Answer {}\n    :5  | func probe(_ x: any Sub.Answer) {}"), "\(search)")
        #expect(search.contains("\nconformers of Answer (1, by written name):\n  Sources.U — struct — Sources/Lib/Lib.swift:4"), "\(search)")
        #expect(!search.contains(Self.noted), "\(search)")
        #expect(!search.contains(Self.marked), "\(search)")
    }

    /// `Outer.Sub.Answer` stays `Base.Answer`'s unnoted, and the typealias writing `Search.Answer` is noted as possibly `Search`'s.
    @Test
    func aNestedSubclassPathIsKeptAndATypealiasOfTheOtherIsNoted() async throws {
        let base = try await WhereQualifiedProtocolNoteTests.answer("Base.Answer", source: "enum Search { protocol Answer {} }\nclass Base { protocol Answer {} }\nenum Outer { class Sub: Base {} }\nenum Other { class Sub { typealias Answer = Search.Answer } }\nstruct U: Outer.Sub.Answer {}\n")

        #expect(base.contains("\"Answer\" used by 2 lines in 1 file — 2 production · 0 tests, split on the XCTest or Testing import, never the path; 1 of them writes \"Answer\" only behind Search, which declares another \"Answer\""), "\(base)")
        #expect(base.contains("\n    :4  | enum Other { class Sub { typealias Answer = Search.Answer } }\n    :5  | struct U: Outer.Sub.Answer {}"), "\(base)")
        #expect(base.contains("\nconformers of Answer (1, by written name):\n  Sources.U — struct — Sources/Lib/Lib.swift:5"), "\(base)")
        #expect(!base.contains(Self.marked), "\(base)")
    }

    /// A generic typealias's and a macro's own `Log` parameter is no type the index declares, so their lines stay uses; their spelling matches the `Log` enum's, so each is noted, never set apart.
    @Test
    func aGenericParametersQualifierIsKeptAndNoted() async throws {
        let prelude = "enum Search { protocol Answer {} }\nenum Log { enum Shelf { protocol Answer {} } }\nprotocol Answering {}\nextension Answering { typealias Answer = Search.Answer }\nprotocol Shelved { associatedtype Shelf: Answering }\n"
        let alias = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: prelude + "typealias Handler<Log: Shelved> = (any Log.Shelf.Answer) -> Void\n")
        let macro = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: prelude + "@freestanding(expression) macro shelve<Log: Shelved>(_ x: Log, _ y: (Log.Shelf.Answer) -> Void) -> Int = #externalMacro(module: \"Lib\", type: \"Shelf\")\n")

        let note = "; 1 of them writes \"Answer\" only behind Log.Shelf, which declares another \"Answer\""

        #expect(alias.contains("\"Answer\" used by 1 line in 1 file — "), "\(alias)")
        #expect(alias.contains(note), "\(alias)")
        #expect(macro.contains("\"Answer\" used by 1 line in 1 file — "), "\(macro)")
        #expect(macro.contains(note), "\(macro)")
        #expect(alias.contains("\n    :6  | typealias Handler<Log: Shelved> = (any Log.Shelf.Answer) -> Void"), "\(alias)")
        #expect(macro.contains("\n    :6  | @freestanding(expression) macro shelve<Log: Shelved>(_ x: Log, _ y: (Log.Shelf.Answer) -> Void)"), "\(macro)")
    }

    /// `Log` beside the line is a nested enum or subclass that is not the top-level `Log`; the spelling matches, so the line is kept, counted and noted, its conformer kept and marked.
    @Test
    func aTypeNestedBesideTheLineIsKeptAndNoted() async throws {
        let search = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search {\n    protocol Answer {}\n}\nenum Log {\n    protocol Answer {}\n}\nenum Outer {\n    enum Log {\n        typealias Answer = Search.Answer\n    }\n    struct Inner: Log.Answer {}\n}\n")
        let base = try await WhereQualifiedProtocolNoteTests.answer("Base.Answer", source: "class Base {\n    protocol Answer {}\n}\nenum Log {\n    protocol Answer {}\n}\nenum Outer {\n    class Log: Base {}\n    struct Inner: Log.Answer {}\n}\n")

        #expect(search.contains("\"Answer\" used by 1 line in 1 file — "), "\(search)")
        #expect(search.contains("; 1 of them writes \"Answer\" only behind Log, which declares another \"Answer\""), "\(search)")
        #expect(search.contains("\n  Sources/Lib/Lib.swift (1):\n    :11  | struct Inner: Log.Answer {}"), "\(search)")
        #expect(search.contains("\nconformers of Answer (1, by written name):\n  Sources.Outer.Inner — struct — Sources/Lib/Lib.swift:11  (clause writes Log.Answer)"), "\(search)")
        #expect(base.contains("\"Answer\" used by 1 line in 1 file — "), "\(base)")
        #expect(base.contains("\n  Sources/Lib/Lib.swift (1):\n    :9  | struct Inner: Log.Answer {}"), "\(base)")
        #expect(base.contains("\nconformers of Answer (1, by written name):\n  Sources.Outer.Inner — struct — Sources/Lib/Lib.swift:9  (clause writes Log.Answer)"), "\(base)")
    }

    /// A `Log` typealias of `Search` — in another module's file, or local to a function — keeps its line and conformer, noted by spelling.
    @Test
    func aTypealiasOfTheAskedOwnerIsKeptAndNoted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Alpha\",\n    targets: [.target(name: \"Alpha\"), .target(name: \"Beta\", dependencies: [\"Alpha\"])]\n)\n", to: "Package.swift", in: root)
        try TestSources.write("public enum Search {\n    public protocol Answer {}\n}\npublic enum Log {\n    public protocol Answer {}\n}\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try TestSources.write("import Alpha\ntypealias Log = Alpha.Search\nstruct Use: Log.Answer {}\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.commitAll(in: root, message: "another module's typealias of the asked owner")
        let engine = try SiftEngine(directory: root)
        let modules = try await engine.lookup(symbol: "Search.Answer", freshness: engine.ensureFresh())
        let local = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search {\n    protocol Answer {}\n}\nenum Log {\n    protocol Answer {}\n}\nfunc probe() {\n    typealias Log = Search\n    let _: (any Log.Answer)? = nil\n}\n")

        #expect(modules.contains("\"Answer\" used by 1 line in 1 file — "), "\(modules)")
        #expect(modules.contains("\n  Sources/Beta/Beta.swift (1):\n    :3  | struct Use: Log.Answer {}"), "\(modules)")
        #expect(modules.contains("\nconformers of Answer (1, by written name):\n  Beta.Use — struct — Sources/Beta/Beta.swift:3  (clause writes Log.Answer)"), "\(modules)")
        #expect(local.contains("\"Answer\" used by 1 line in 1 file — "), "\(local)")
        #expect(local.contains("; 1 of them writes \"Answer\" only behind Log, which declares another \"Answer\""), "\(local)")
        #expect(local.contains("\n  Sources/Lib/Lib.swift (1):\n    :9  | let _: (any Log.Answer)? = nil"), "\(local)")
    }

    /// A `Log` that is a typealias, where the other `Answer` sits under `Other`, spells no other owner, so its lines and conformers are kept unnoted.
    @Test
    func aQualifierSpellingNoOtherOwnerIsKeptUnnoted() async throws {
        let own = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nenum Other { protocol Answer {} }\ntypealias Log = Search\nstruct S: Log.Answer { typealias Log = Other }\n")
        let extended = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nenum Other { protocol Answer {} }\ntypealias Log = Search\nstruct V {}\nextension V { typealias Log = Other }\nextension V: Log.Answer {}\n")
        let shadowed = try await WhereQualifiedProtocolNoteTests.answer("Search.Answer", source: "enum Search { protocol Answer {} }\nenum Other { protocol Answer {} }\nenum Outer {\n    typealias Log = Other\n    enum Inner {\n        enum Log { typealias Answer = Search.Answer }\n        struct Use: Log.Answer {}\n        static func probe() { let _: (any Log.Answer)? = nil }\n    }\n}\n")

        #expect(own.contains("\"Answer\" used by 1 line in 1 file — 1 production · 0 tests, split on the XCTest or Testing import, never the path (for Sources.Search.Answer):\n  Sources/Lib/Lib.swift (1):\n    :4  | struct S: Log.Answer { typealias Log = Other }"), "\(own)")
        #expect(own.contains("\nconformers of Answer (1, by written name):\n  Sources.S — struct — Sources/Lib/Lib.swift:4"), "\(own)")
        #expect(extended.contains("\"Answer\" used by 1 line in 1 file — 1 production · 0 tests, split on the XCTest or Testing import, never the path (for Sources.Search.Answer):\n  Sources/Lib/Lib.swift (1):\n    :6  | extension V: Log.Answer {}"), "\(extended)")
        #expect(extended.contains("\nconformers of Answer (1, by written name):\n  Sources.V — extension — Sources/Lib/Lib.swift:6"), "\(extended)")
        #expect(shadowed.contains("\"Answer\" used by 2 lines in 1 file — "), "\(shadowed)")
        #expect(shadowed.contains("\n  Sources/Lib/Lib.swift (2):\n    :7  | struct Use: Log.Answer {}\n    :8  | static func probe() { let _: (any Log.Answer)? = nil }"), "\(shadowed)")
        #expect(shadowed.contains("\nconformers of Answer (1, by written name):\n  Sources.Outer.Inner.Use — struct — Sources/Lib/Lib.swift:7"), "\(shadowed)")
        #expect(!shadowed.contains(Self.noted), "\(shadowed)")
        for answer in [own, extended, shadowed] {
            #expect(!answer.contains(Self.marked), "\(answer)")
        }
    }

    /// Under `--at`, a revision's line written behind the other owner's spelling is kept and noted.
    @Test
    func aRevisionsLineIsKeptAndNoted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum Search { protocol Answer {} }\nenum Log { protocol Answer {} }\nfunc probe() {\n    typealias Log = Search\n    let _: (any Log.Answer)? = nil\n}\n", to: "Sources/Lib/Lib.swift", in: root)
        try TestSources.commitAll(in: root, message: "a typealias local to a function, read at a revision")

        let search = try await SiftEngine(directory: root).lookup(symbol: "Search.Answer", at: "HEAD")

        #expect(search.contains("\n    :5  | let _: (any Log.Answer)? = nil"), "\(search)")
        #expect(search.contains("; 1 of them writes \"Answer\" only behind Log, which declares another \"Answer\""), "\(search)")
    }
}
