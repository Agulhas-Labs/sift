//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `where` and `digest` of `Type.deinit` for a type with no deinit say that its source was read and holds none, and say instead that it could not be checked where the source could not be read.
///
/// The index never holds a deinit, so the absence wording of a missing declaration (`no declarations found`, `no symbol named deinit in the index`) is true of every type and tells the reader nothing about this one.
@Suite(.serialized, .temporaryDirectories)
struct WhereDeinitAbsenceTests {
    static var shapes: String {
        """
        final class Plain {}

        final class Circle {
            deinit {}
        }
        """
    }

    static var path: String {
        "Sources/App/Shapes.swift"
    }

    static func engine() async throws -> (SiftEngine, URL) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(shapes, to: path, in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return (engine, root)
    }

    /// A type whose source was read and holds no deinit is answered as declaring none, in both tools.
    @Test
    func aTypeWithNoDeinitIsSaidToDeclareNone() async throws {
        let (engine, _) = try await Self.engine()
        let located = try await engine.lookup(symbol: "Plain.deinit", freshness: engine.ensureFresh())
        let digested = try engine.digest(target: "Plain.deinit", options: DigestOptions())
        let none = "Plain declares no deinit — checked in its source, \(Self.path):1"

        #expect(located.contains(none), "\(located)")
        #expect(!located.contains("no declarations found"), "\(located)")
        #expect(digested.contains(none), "\(digested)")
        #expect(!digested.contains("no symbol named"), "\(digested)")
    }

    /// A type whose source cannot be read is named as unchecked, never as declaring none, in the lines of both tools.
    ///
    /// Driven through the lookup with a reader that fails, because a file made unreadable on disk is re-indexed away before any answer reads it.
    @Test
    func aTypeWhoseSourceCannotBeReadIsNotSaidToDeclareNone() async throws {
        let (engine, root) = try await Self.engine()
        let lookup = try #require(try DeinitLookup(store: engine.store) { _ in nil }.lookup(for: "Plain.deinit"))
        let located = DeinitLookup.whereLines(for: lookup, cap: WhereRenderer.listCap).joined(separator: "\n")
        let digested = DeinitLookup.digestAnswer(for: lookup, target: "Plain.deinit", preamble: [], under: root)
        let unchecked = "Plain for a deinit: its source could not be read (\(Self.path):1)"

        for answer in [located, digested] {
            #expect(answer.hasPrefix("could not check "), "\(answer)")
            #expect(answer.contains(unchecked), "\(answer)")
            #expect(!answer.contains("declares no deinit"), "\(answer)")
        }
    }

    /// A path naming no type keeps the absence wording of a missing declaration: there is no type to read.
    @Test
    func aPathNamingNoTypeIsNotAnsweredAboutADeinit() async throws {
        let (engine, _) = try await Self.engine()
        let located = try await engine.lookup(symbol: "Square.deinit", freshness: engine.ensureFresh())

        #expect(!located.contains("declares no deinit"), "\(located)")
        #expect(!located.contains("could not check"), "\(located)")
    }
}
