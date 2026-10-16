//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a name-matched call list keeping a call written on an array, dictionary or optional type, which may hand an instance method its instance.
///
/// `[Int].chunked([1])` names an instance method of `Array` on its type and gives it only its instance, so its labels say nothing about the method's; read as a value, the receiver left the call judged as a direct one and dropped for the labels it leaves out.
@Suite(.temporaryDirectories)
struct WhereArrayTypeReceiverTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// An instance method of `Array` called on an array type with one unlabeled value is kept whatever the method's labels.
    @Test
    func anArrayTypeReceiverMayHandItsInstance() async throws {
        let output = try await Self.lookup(
            "Array.chunked",
            declaring: """
            extension Array {
                func chunked(into size: Int) -> [[Element]] { [] }
            }
            """,
            calling: """
            struct Calls {
                func one() { _ = [Int].chunked([1]) }
                func two() { _ = [1, 2].chunked(into: 1) }
                func three() { _ = Widget.chunked(1, scale: 2) }
            }
            """
        )

        #expect(output.contains("\"chunked\" (3 call sites by written name, 2 with the labels (into:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A dictionary type spelled `[K: V]` is a type too, so an instance method of `Dictionary` keeps its call.
    @Test
    func aDictionaryTypeReceiverMayHandItsInstance() async throws {
        let output = try await Self.lookup(
            "Dictionary.merged",
            declaring: """
            extension Dictionary {
                func merged(with other: [Key: Value]) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let d = ["a": 1]
                func one() { _ = [String: Int].merged(d) }
                func two() { _ = d.merged(with: d) }
                func three() { _ = Widget.merged(d, scale: 2) }
            }
            """
        )

        #expect(output.contains("\"merged\" (3 call sites by written name, 2 with the labels (with:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A nested array type, or a dictionary type whose value is one, may be a type as its elements may.
    @Test
    func aNestedCollectionTypeReceiverMayHandItsInstance() async throws {
        let output = try await Self.lookup(
            "Array.flat",
            declaring: """
            extension Array {
                func flat(depth: Int) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let x = [[1]]
                func one() { _ = [[Int]].flat(x) }
                func two() { _ = [String: [Int]].flat(x) }
                func three() { _ = x.flat(depth: 1) }
                func four() { _ = Widget.flat(x, scale: 2) }
            }
            """
        )

        #expect(output.contains("\"flat\" (4 call sites by written name, 3 with the labels (depth:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(output.contains("in Calls.three()"))
        #expect(!output.contains("in Calls.four()"))
    }

    /// An optional type spelled `T?` is a type as `T` is, so an instance method of `Optional` keeps its call.
    @Test
    func anOptionalTypeReceiverMayHandItsInstance() async throws {
        let output = try await Self.lookup(
            "Optional.pick",
            declaring: """
            extension Optional {
                func pick(from x: Int) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let a: Int? = nil
                func one() { _ = Int?.pick(nil) }
                func two() { _ = a.pick(from: 1) }
                func three() { _ = a?.pick(nil) }
            }
            """
        )

        #expect(output.contains("\"pick\" (3 call sites by written name, 2 with the labels (from:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A static method has no instance to be handed, so its call on an array type leaving out a required label is still dropped.
    @Test
    func aStaticMethodsCallOnAnArrayTypeLeavingOutALabelIsDropped() async throws {
        let output = try await Self.lookup(
            "Array.make",
            declaring: """
            extension Array {
                static func make(_ x: Int, scale: Int) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                func one() { _ = [Int].make(1, scale: 2) }
                func two() { _ = [Int].make(1) }
            }
            """
        )

        #expect(output.contains("\"make\" (2 call sites by written name, 1 with the labels (_:scale:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(!output.contains("in Calls.two()"))
    }

    /// An array literal of values is not a type, so a call on it is judged by its labels as before.
    @Test
    func anArrayLiteralOfValuesIsNotAType() async throws {
        let output = try await Self.lookup(
            "Array.chunked",
            declaring: """
            extension Array {
                func chunked(into size: Int) -> [[Element]] { [] }
            }
            """,
            calling: """
            struct Calls {
                func one() { _ = [1].chunked([1]) }
                func two() { _ = [1].chunked(into: 1) }
            }
            """
        )

        #expect(output.contains("\"chunked\" (2 call sites by written name, 1 with the labels (into:), in 1 file"))
        #expect(!output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
    }
}
