//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an initializer's implied call sites, written with a leading dot, whose declared type is wrapped in parentheses.
///
/// With no index store a parenthesised type, `(Other)`, is the type inside it, so the use folds in as the bare spelling does.
@Suite(.temporaryDirectories)
struct WhereImpliedInitParenTypeTests {
    private static let implied = "." + "init"

    private static var untold: String {
        "on a type the scan cannot tell"
    }

    private static func lookup(calling calls: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Other { init(_ s: String) {} }", to: "Sources/App/Types.swift", in: root)
        try TestSources.write(calls, to: "Sources/App/Calls.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: "Other.init", freshness: freshness)
    }

    /// The answer without its tree header line and the source text each site quotes, which spells the type being compared.
    private static func answer(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().map { line in
            line.components(separatedBy: " | ")[0]
        }
    }

    private static func source(_ shape: Int, type: String) -> String {
        let call = "\(implied)(\"v\")"
        return switch shape {
        case 0: "func f() -> \(type) { \(call) }"
        case 1: "let x: \(type) = \(call)"
        case 2: "let e: () -> \(type) = { \(call) }"
        default: "let e = { () -> \(type) in \(call) }"
        }
    }

    @Test(arguments: 0 ..< 4)
    func aParenthesisedTypeFoldsAsTheBareSpellingDoes(shape: Int) async throws {
        let bare = try await Self.lookup(calling: Self.source(shape, type: "Other"))
        let paren = try await Self.lookup(calling: Self.source(shape, type: "(Other)"))

        #expect(!bare.contains(Self.untold), "\(bare)")
        #expect(Self.answer(paren) == Self.answer(bare), "\(paren)\n--- bare:\n\(bare)")
    }

    @Test
    func aDoublyParenthesisedTypeFoldsAsTheBareSpellingDoes() async throws {
        let bare = try await Self.lookup(calling: Self.source(0, type: "Other"))
        let paren = try await Self.lookup(calling: Self.source(0, type: "((Other))"))

        #expect(Self.answer(paren) == Self.answer(bare), "\(paren)\n--- bare:\n\(bare)")
    }

    @Test(arguments: ["(label: Other)", "(Other, Other)"])
    func aTupleOfNoSingleTypeIsNotAUse(type: String) async throws {
        let output = try await Self.lookup(calling: Self.source(0, type: type))

        #expect(!output.contains("1 written as"), "\(output)")
        #expect(!output.contains("in f()"), "\(output)")
    }
}
