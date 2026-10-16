//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the uses a qualified query's name-matched answer counts as written with no call, judged by the type a `T.f` is written on.
///
/// A function handed on unapplied as `Widget.of`, where `Widget` is a type the tree declares that is none of the declaring type, its typealiases or its subtypes, cannot be the function asked about, so it is dropped from the uses written with no call and counted, as a call on `Widget` is.
@Suite(.temporaryDirectories)
struct WhereNameOnlyReceiverTests {
    private static var declarations: String {
        """
        class Gizmo {
            static func of(_ value: Int) -> Int { value }
        }
        final class Sub: Gizmo {}
        typealias Gadget = Gizmo
        struct Widget {
            static func of(_ value: Int) -> Int { value }
        }
        """
    }

    private static func lookup(_ symbol: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// `Widget.of` handed on is the unrelated `Widget`'s own: dropped and counted, while the uses beside it stay.
    @Test
    func aReferenceOnAnUnrelatedTreeTypeIsDroppedAndCounted() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func widget() { _ = a.map(Widget.of) }
                func bare() { _ = a.map(of) }
            }
            """
        )

        #expect(output.contains("but the name is written 2 times with no call, 1 on other types dropped, 1 kept — a function handed on unapplied"))
        #expect(!output.contains("in Calls.widget()"))
        #expect(output.contains("in Calls.bare()"))
    }

    /// Where every use written with no call is on an unrelated type, the section still says how many were dropped.
    @Test
    func everyReferenceDroppedIsStillCounted() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func widget() { _ = a.map(Widget.of) }
            }
            """
        )

        #expect(output.contains("but the name is written once with no call, 1 on other types dropped, none kept"))
        #expect(!output.contains("in Calls.widget()"))
    }

    /// `Gizmo.of` handed on is the declaring type's own and is listed with the calls.
    @Test
    func aReferenceOnTheDeclaringTypeIsKept() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func own() { _ = a.map(Gizmo.of) }
            }
            """
        )

        #expect(output.contains("in Calls.own()"))
        #expect(!output.contains("on other types dropped"))
    }

    /// A typealias of the declaring type and a subclass of it may reach the function, so both stay.
    @Test
    func referencesThroughATypealiasOrASubtypeAreKept() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func alias() { _ = a.map(Gadget.of) }
                func sub() { _ = a.map(Sub.of) }
            }
            """
        )

        #expect(output.contains("but the name is written 2 times with no call — a function handed on unapplied"))
        #expect(output.contains("in Calls.alias()"))
        #expect(output.contains("in Calls.sub()"))
        #expect(!output.contains("on other types dropped"))
    }

    /// A bare `of` and a type the tree does not declare cannot be judged, so both stay, the latter counted by why.
    @Test
    func bareAndUndeclaredReferencesAreKept() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func bare() { _ = a.map(of) }
                func foreign() { _ = a.map(Foreign.of) }
            }
            """
        )

        #expect(output.contains("but the name is written 2 times with no call, 1 on types the tree does not declare (Foreign ×1) — a function handed on unapplied"))
        #expect(output.contains("in Calls.bare()"))
        #expect(output.contains("in Calls.foreign()"))
        #expect(!output.contains("on other types dropped"))
    }

    /// A compound `Widget.of(_:)` handed on states the labels and is listed with the calls, where an unrelated `Widget` drops it as a call on it is dropped.
    @Test
    func aCompoundReferenceOnAnUnrelatedTreeTypeIsDropped() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            calling: """
            struct Calls {
                let a = [1]
                func own() { _ = a.map(Gizmo.of(_:)) }
                func widget() { _ = a.map(Widget.of(_:)) }
            }
            """
        )

        #expect(output.contains("1 on other types dropped, 1 kept"))
        #expect(output.contains("in Calls.own()"))
        #expect(!output.contains("in Calls.widget()"))
    }
}
