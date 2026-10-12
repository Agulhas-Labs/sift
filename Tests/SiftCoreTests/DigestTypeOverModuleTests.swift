//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A bare digest target naming both a module and a type serves the type, and says how to reach the module.
@Suite(.temporaryDirectories)
struct DigestTypeOverModuleTests {
    private static func render(_ target: String, extraType: Bool = false) throws -> String {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        var files = try [
            TestSources.parsed("public actor Gizmo {\n    func spin() {}\n}\n", path: "Sources/GizmoCore/Gizmo.swift", in: root),
            TestSources.parsed("public struct Helper {}\n", path: "Sources/Gizmo/Helper.swift", in: root),
            TestSources.parsed("public struct Lonely {}\n", path: "Sources/Solo/Lonely.swift", in: root),
        ]
        if extraType {
            try files.append(TestSources.parsed("public struct Gizmo {}\n", path: "Sources/Other/Gizmo.swift", in: root))
        }
        try store.replaceFiles(files) { file in
            (file.split(separator: "/").dropFirst().first.map(String.init) ?? "", false)
        }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.render(target: target, options: DigestOptions())
    }

    @Test
    func aBareNameOfAModuleAndATypeServesTheTypeAndNamesTheModuleSpelling() throws {
        let output = try Self.render("Gizmo")

        #expect(output.contains("actor Gizmo"))
        #expect(!output.contains("top-level declarations"))
        #expect(output.hasSuffix("a module named Gizmo also exists — `digest Gizmo/` serves it"))
    }

    @Test
    func theExplicitModuleSpellingServesTheModule() throws {
        let output = try Self.render("Gizmo/")

        #expect(output.contains("module Gizmo — 1 top-level declarations"))
        #expect(output.contains("struct Helper"))
        #expect(output.contains("a type named Gizmo also exists"))
    }

    @Test
    func severalTypesAndAModuleKeepTheAmbiguityAnswerAndAddTheModuleLine() throws {
        let output = try Self.render("Gizmo", extraType: true)

        #expect(output.contains("Gizmo is ambiguous — 2 declarations"))
        #expect(output.hasSuffix("a module named Gizmo also exists — `digest Gizmo/` serves it"))
    }

    @Test
    func aMissOnAModuleSpellingSaysNoModuleIsNamedSoEither() throws {
        let output = try Self.render("Nope/")

        #expect(output.contains("no indexed file matches Nope/"))
        #expect(output.hasSuffix("no module named Nope either"))
    }

    /// A repository whose module `Gizmo` holds a type `Gizmo`, and whose module `Solo` holds none of its name, committed.
    private static func revisionRepo() throws -> (engine: SiftEngine, head: String) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("public struct Gizmo {\n    public func spin() {}\n}\n", to: "Gizmo/Gizmo.swift", in: root)
        try TestSources.write("public struct Extra {}\n", to: "Gizmo/Extra.swift", in: root)
        try TestSources.write("public struct Lonely {}\n", to: "Solo/Lonely.swift", in: root)
        try TestSources.commitAll(in: root, message: "modules")
        let head = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        return try (SiftEngine(directory: root), head)
    }

    @Test
    func theModuleSpellingAtARevisionIsRefusedNeverCountedAsAnEmptyModule() throws {
        let repo = try Self.revisionRepo()

        let error = #expect(throws: EngineError.self) {
            try repo.engine.digest(targets: ["Gizmo/"], at: repo.head, options: DigestOptions())
        }

        #expect(error?.description.contains("`Gizmo/` is a module") == true, "\(String(describing: error))")
    }

    @Test
    func aBareNameOfAModuleAndATypeAtARevisionServesTheType() throws {
        let repo = try Self.revisionRepo()

        let answer = try repo.engine.digest(targets: ["Gizmo"], at: repo.head, options: DigestOptions())

        #expect(answer.contains("public func spin() {}"), "\(answer)")
        #expect(!answer.contains("top-level declarations"), "\(answer)")
        #expect(!answer.contains("digest Gizmo/"), "\(answer)")
        #expect(answer.contains("a module named Gizmo also exists"), "\(answer)")
    }

    @Test
    func aBareModuleNameWithNoTypeOfItsNameIsStillRefusedAtARevision() throws {
        let repo = try Self.revisionRepo()

        let error = #expect(throws: EngineError.self) {
            try repo.engine.digest(targets: ["Solo"], at: repo.head, options: DigestOptions())
        }

        #expect(error?.description.contains("`Solo` is a module") == true, "\(String(describing: error))")
    }

    @Test
    func aModuleWithNoTypeOfItsNameIsUnchanged() throws {
        let output = try Self.render("Solo")

        #expect(output.contains("module Solo — 1 top-level declarations"))
        #expect(!output.contains("a module named"))
    }
}
