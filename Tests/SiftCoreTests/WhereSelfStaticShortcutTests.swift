//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A call `Self.make(g)` written inside the owner keeps its flag only where an instance method of the name could take `g` as its instance.
@Suite(.temporaryDirectories)
struct WhereSelfStaticShortcutTests {
    /// The no-store `where` answer for `Gizmo.make` over a `Gizmo` declared with `members`, a `Self.make(g)` inside it and an `Other.make(g)` beside it.
    private static func answer(members: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Gizmo {\n\(members)\n    static func build(_ g: Gizmo) { Self.make(g) }\n}\nstruct Other {\n    static func make(count: Int) {}\n    func use(_ g: Gizmo) { Other.make(g) }\n}\n",
            to: "Sources/App/Gizmo.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Gizmo.make", in: root)
    }

    /// Every declared make is static, so no instance reaches the call and its labels drop it as they drop the call written on another type.
    @Test
    func aStaticOnlyMakeDropsTheSelfCallWhoseLabelsFit() async throws {
        let output = try await Self.answer(members: "    static func make(count: Int) -> Gizmo { Gizmo() }")

        #expect(!output.contains("in Gizmo.build("))
        #expect(!output.contains("in Other.use("))
        #expect(!output.contains("(may be unapplied on Self)"))
        #expect(output.contains("2 call sites by name, none with the labels (count:)"))
    }

    /// An instance make could take `g` as its instance, so the call stays listed and flagged.
    @Test
    func anInstanceMakeKeepsTheSelfCallFlagged() async throws {
        let output = try await Self.answer(members: "    func make(count: Int) -> Gizmo { Gizmo() }")

        let row = try #require(output.split(separator: "\n").first { $0.contains("in Gizmo.build(") })

        #expect(row.contains("(may be unapplied on Self)"))
    }

    /// A static and an instance overload side by side keep the flag, since the instance one may take `g`.
    @Test
    func aStaticAndAnInstanceOverloadKeepTheFlag() async throws {
        let output = try await Self.answer(members: "    static func make(count: Int) -> Gizmo { Gizmo() }\n    func make(size: Int) -> Gizmo { Gizmo() }")

        let row = try #require(output.split(separator: "\n").first { $0.contains("in Gizmo.build(") })

        #expect(row.contains("(may be unapplied on Self)"))
    }
}
