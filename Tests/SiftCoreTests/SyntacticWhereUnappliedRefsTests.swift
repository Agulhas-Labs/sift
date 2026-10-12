//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With no index store, every line a function's name is written on stays in `where`'s answer: a bare `restock` with no call is shown beside the list of its calls, under the same line that shows it where nothing is listed.
///
/// Shown only where no call was listed, a function both called and handed on unapplied as `let r = restock` lost that line from the answer, plain and under `--refs`, while a store's answer lists it as referenced, not called.
@Suite(.temporaryDirectories)
struct SyntacticWhereUnappliedRefsTests {
    static var depot: String {
        """
        // Depot
        func restock() {}
        func use() {
            restock(); restock()
            restock()
            let r = restock
            _ = r
        }
        """
    }

    static var fire: String {
        """
        func fire() {}
        func arm() {
            let f = fire
            _ = f
        }
        """
    }

    static var nameOnly: String {
        "but the name is written once with no call"
    }

    static func answer(_ symbol: String, source: String, at path: String, references: Bool = false) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: path, in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: references))
    }

    /// The rows of a `where` answer one per line (``WhereAnswerRepetitionTests/sitesOnePerLine(_:)``), split at the line that opens the name written with no call: the listed sites before it, and the rows it shows after it.
    static func listedAndWrittenWithNoCall(_ output: String) -> (listed: String, writtenWithNoCall: String) {
        guard let block = output.range(of: "but the name is written") else {
            return (WhereAnswerRepetitionTests.sitesOnePerLine(output), "")
        }
        return (
            WhereAnswerRepetitionTests.sitesOnePerLine(String(output[..<block.lowerBound])),
            WhereAnswerRepetitionTests.sitesOnePerLine(String(output[block.lowerBound...]))
        )
    }

    /// The calls are listed and the unapplied line follows them, so neither is missing from the answer.
    static func expectCallsAndUnappliedLine(_ output: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let (listed, written) = listedAndWrittenWithNoCall(output)
        #expect(output.contains("\"restock\" (3 call sites by written name in 1 file):"), "\(output)", sourceLocation: sourceLocation)
        #expect(listed.components(separatedBy: "Sources/App/Depot.swift:4  in use()\n").count == 3, "\(output)", sourceLocation: sourceLocation)
        #expect(listed.contains("Sources/App/Depot.swift:5  in use()"), "\(output)", sourceLocation: sourceLocation)
        #expect(!listed.contains("Sources/App/Depot.swift:6"), "\(output)", sourceLocation: sourceLocation)
        #expect(output.contains(nameOnly), "\(output)", sourceLocation: sourceLocation)
        #expect(written.contains("Sources/App/Depot.swift:6  in use().r"), "\(output)", sourceLocation: sourceLocation)
    }

    @Test
    func aCalledFunctionsUnappliedLineIsShownBesideItsCalls() async throws {
        let output = try await Self.answer("restock", source: Self.depot, at: "Sources/App/Depot.swift")
        Self.expectCallsAndUnappliedLine(output)
    }

    @Test
    func aCalledFunctionsUnappliedLineIsShownInAReferencesSweep() async throws {
        let output = try await Self.answer("restock", source: Self.depot, at: "Sources/App/Depot.swift", references: true)

        #expect(output.contains("no store for callers, overrides or references; sites by written name"), "\(output)")
        Self.expectCallsAndUnappliedLine(output)
    }

    @Test
    func aFunctionWithNoCallStillShowsItsUnappliedLine() async throws {
        let output = try await Self.answer("fire", source: Self.fire, at: "Sources/App/Fire.swift")

        #expect(output.contains("no call spelled \"fire\" anywhere in the working tree"), "\(output)")
        #expect(output.contains(Self.nameOnly), "\(output)")
        #expect(Self.listedAndWrittenWithNoCall(output).writtenWithNoCall.contains("Sources/App/Fire.swift:3  in arm().f"), "\(output)")
    }
}
