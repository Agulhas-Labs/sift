//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where` and `digest` of `Type.deinit` resolve a deinitializer the index never stores.
///
/// A deinit has no name and no symbol kind, so a lookup by member name found nothing under the type and the path read as a declaration that does not exist, said of one written in plain sight.
@Suite(.temporaryDirectories)
struct WhereDeinitTests {
    static var shapes: String {
        """
        final class Circle {
            var radius = 1

            deinit {
                radius = 0
            }

            final class Inner {
                deinit {}
            }
        }

        final class Plain {}
        """
    }

    static func engine() async throws -> (SiftEngine, Freshness) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shapes, to: "Sources/App/Shapes.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        return try await (engine, engine.ensureFresh())
    }

    /// `where Circle.deinit` lists the deinit at its own lines, not the type's, and not the inner type's.
    @Test
    func whereResolvesATypesDeinit() async throws {
        let (engine, freshness) = try await Self.engine()
        let output = try await engine.lookup(symbol: "Circle.deinit", freshness: freshness)

        #expect(!output.contains("no declarations found"), "\(output)")
        #expect(output.contains("declarations (1):"), "\(output)")
        #expect(output.contains("Circle.deinit — deinit — Sources/App/Shapes.swift:4-6"), "\(output)")
    }

    /// The inner type's deinit answers to its own path.
    @Test
    func aNestedTypesDeinitResolvesUnderItsOwnPath() async throws {
        let (engine, freshness) = try await Self.engine()
        let output = try await engine.lookup(symbol: "Circle.Inner.deinit", freshness: freshness)

        #expect(output.contains("Circle.Inner.deinit — deinit — Sources/App/Shapes.swift:9"), "\(output)")
    }

    /// `digest Circle.deinit` serves the deinit's source.
    @Test
    func digestServesATypesDeinitSource() async throws {
        let (engine, _) = try await Self.engine()
        let answer = try engine.digest(target: "Circle.deinit", options: DigestOptions())

        #expect(!answer.contains("no symbol named"), "\(answer)")
        #expect(answer.contains("Circle.deinit — deinit — Sources/App/Shapes.swift:4-6"), "\(answer)")
        #expect(answer.contains("    deinit {\n        radius = 0\n    }"), "\(answer)")
    }

    /// A class with no deinit is still answered as one with none.
    @Test
    func aTypeWithoutADeinitStillMisses() async throws {
        let (engine, freshness) = try await Self.engine()
        let output = try await engine.lookup(symbol: "Plain.deinit", freshness: freshness)

        #expect(!output.contains("declarations (1):"), "\(output)")
    }
}
