//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A search for a type kind with a body term that misses says why: a type is matched on its own declaration's body, not its extensions'.
@Suite(.temporaryDirectories)
struct SearchTypeBodyMissTests {
    private static var note: String {
        "a type is matched on its own declaration's body, not its extensions'"
    }

    private func searched(_ query: String, source: String, count: Bool = false) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await SiftEngine(directory: root).search(query: query, count: count)
    }

    private static var callInExtension: String {
        """
        struct Depot {
            var title: String { "Depot" }
        }

        extension Depot {
            var shelf: Int { Gizmo() }
        }
        """
    }

    @Test
    func aTypeKindMissWhoseCallIsInAnExtensionNamesTheExtensionsAndTheQueryThatFindsThem() async throws {
        let answer = try await searched("kind:struct calls:Gizmo", source: Self.callInExtension)

        #expect(answer.contains("\(Self.note) — 1 extension(s) match: search 'kind:extension calls:Gizmo'"), "\(answer)")
    }

    @Test
    func theCountAnswerCarriesTheSameLine() async throws {
        let answer = try await searched("kind:struct calls:Gizmo", source: Self.callInExtension, count: true)

        #expect(answer.contains("1 extension(s) match: search 'kind:extension calls:Gizmo'"), "\(answer)")
    }

    @Test
    func aTypeKindMissNoExtensionExplainsCarriesNoSuchLine() async throws {
        let answer = try await searched("kind:struct calls:Nowhere", source: Self.callInExtension)

        #expect(answer.contains("no declarations match"), "\(answer)")
        #expect(!answer.contains(Self.note), "\(answer)")
    }

    @Test
    func aNegatedBodyTermCarriesNoSuchLine() async throws {
        let source = "struct Depot {\n    func load() { Gizmo() }\n}\n\nextension Depot {\n    var shelf: Int { Gizmo() }\n}\n"
        let answer = try await searched("kind:struct !calls:Gizmo", source: source)

        #expect(!answer.contains(Self.note), "\(answer)")
    }

    @Test
    func aFunctionKindMissCarriesNoSuchLine() async throws {
        let answer = try await searched("kind:func calls:Nowhere", source: Self.callInExtension)

        #expect(answer.contains("no declarations match"), "\(answer)")
        #expect(!answer.contains(Self.note), "\(answer)")
    }

    @Test
    func anExtensionKindMissCarriesNoSuchLine() async throws {
        let answer = try await searched("kind:extension calls:Nowhere", source: Self.callInExtension)

        #expect(!answer.contains(Self.note), "\(answer)")
    }

    @Test
    func aStructWhoseOwnBodyHoldsTheCallMatchesAndCarriesNoSuchLine() async throws {
        let answer = try await searched("kind:struct calls:Gizmo", source: "struct Depot {\n    var shelf: Int { Gizmo() }\n}\n")

        #expect(answer.contains("1 declaration(s)"), "\(answer)")
        #expect(!answer.contains(Self.note), "\(answer)")
    }
}
