//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a name-matched call list narrowed by a declaration's required labels when the call is written on a type.
///
/// A call of one unlabeled argument written on a type, `Other.of(x)`, was kept for every declaration of the name, as if it could hand an instance method its instance; a static member or a free function has no instance, so such a call leaving out a label it requires cannot be its call and is dropped.
@Suite(.temporaryDirectories)
struct WhereRequiredLabelTests {
    private static func lookup(_ symbol: String, declaring declarations: String, calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declarations, to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A static member's calls on other types that leave out its required label are dropped and counted; its own calls stay.
    @Test
    func aCallLeavingOutARequiredLabelIsDropped() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            declaring: """
            struct Gizmo {
                static func of(
                    _ items: [Int],
                    census: Int,
                    accessibility: [Int] = []
                ) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let a = [1]
                func one() { _ = Gizmo.of(a, census: 1) }
                func two() { _ = Gizmo.of(a, census: 1, accessibility: []) }
                func three() { _ = Widget.of(a) }
                func four() { _ = Sprocket.of(a, scale: 2) }
            }
            """
        )

        #expect(output.contains("\"of\" (4 call sites by written name, 2 with the labels (_:census:accessibility:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
        #expect(!output.contains("in Calls.four()"))
    }

    /// A free function has no instance either, so a call on a type leaving out its required label is dropped.
    @Test
    func aFreeFunctionsCallLeavingOutARequiredLabelIsDropped() async throws {
        let output = try await Self.lookup(
            "tally",
            declaring: """
            func tally(_ items: [Int], census: Int) -> Int { 0 }
            """,
            calling: """
            struct Calls {
                let a = [1]
                func one() { _ = tally(a, census: 1) }
                func two() { _ = Widget.tally(a) }
            }
            """
        )

        #expect(output.contains("\"tally\" (2 call sites by written name, 1 with the labels (_:census:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(!output.contains("in Calls.two()"))
    }

    /// A trailing closure binds a required closure parameter, written after the parentheses or inside them.
    @Test
    func aTrailingClosureBindsARequiredParameter() async throws {
        let output = try await Self.lookup(
            "Gizmo.run",
            declaring: """
            struct Gizmo {
                static func run(_ x: Int, then: () -> Void) {}
            }
            """,
            calling: """
            struct Calls {
                func one() { Gizmo.run(1) {} }
                func two() { Gizmo.run(1, then: {}) }
                func three() { Widget.run(1) }
            }
            """
        )

        #expect(output.contains("\"run\" (3 call sites by written name, 2 with the labels (_:then:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A variadic or a defaulted parameter left out is not required, so a call of one unlabeled value on the type stays.
    @Test
    func aVariadicOrDefaultedParameterLeftOutIsKept() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            declaring: """
            struct Gizmo {
                static func of(_ items: Int..., census: Int = 0) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                func one() { _ = Gizmo.of(1) }
                func two() { _ = Gizmo.of(census: 1) }
                func three() { _ = Widget.of(scale: 1) }
            }
            """
        )

        #expect(output.contains("\"of\" (3 call sites by written name, 2 with the labels (_:census:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// An instance method's call of one unlabeled value on a type may hand it its instance, so it stays whatever the method's labels.
    @Test
    func anInstanceMethodKeepsACallThatMayHandItsInstance() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            declaring: """
            struct Gizmo {
                func of(_ items: [Int], census: Int) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let a = [1]
                func one() { _ = Gizmo.of(a, census: 1) }
                func two() { _ = Gizmo.of(Gizmo()) }
                func three() { _ = Widget.of(a, scale: 2) }
            }
            """
        )

        #expect(output.contains("\"of\" (3 call sites by written name, 2 with the labels (_:census:), in 1 file"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
        #expect(!output.contains("in Calls.three()"))
    }

    /// A signature whose labels cannot be read back narrows nothing, so a call leaving out a label stays.
    @Test
    func unreadableLabelsNarrowNothing() async throws {
        let output = try await Self.lookup(
            "Gizmo.of",
            declaring: """
            struct Gizmo {
                static func of(_ items: [Int], // a note
                               census: Int) -> Int { 0 }
            }
            """,
            calling: """
            struct Calls {
                let a = [1]
                func one() { _ = Gizmo.of(a, census: 1) }
                func two() { _ = Widget.of(a) }
            }
            """
        )

        #expect(!output.contains("with the labels"))
        #expect(output.contains("in Calls.one()"))
        #expect(output.contains("in Calls.two()"))
    }
}
