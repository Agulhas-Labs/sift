//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers smart-case matching of `strings` against Swift string literals: a query holding an uppercase letter matches case-sensitively, an all-lowercase query stays case-insensitive.
@Suite(.temporaryDirectories)
struct StringsSmartCaseTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "smart case fixture")
        return try SiftEngine(directory: root)
    }

    @Test
    func anUppercaseQueryExcludesALowercaseOnlyMatch() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/DepotStore.swift":
                """
                struct DepotStore {
                    let prose = "the request was refused"
                    let code = "semantic REFUSED"
                }
                """,
        ])

        let output = try engine.strings(query: "REFUSED")

        #expect(output.contains("semantic REFUSED"))
        #expect(!output.contains("the request was refused"))
    }

    @Test
    func aLowercaseQueryStillMatchesMixedCaseText() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/DepotStore.swift":
                """
                struct DepotStore {
                    let code = "semantic REFUSED"
                }
                """,
        ])

        let output = try engine.strings(query: "refused")

        #expect(output.contains("semantic REFUSED"))
    }

    @Test
    func theMoreCountAgreesWithTheCaseSensitiveRows() throws {
        var members = ""
        for index in 0 ..< (SourceLiteralSearch.siteCap + 3) {
            members += "    let upper\(index) = \"MARKER\(index)\"\n"
            members += "    let lower\(index) = \"marker\(index)\"\n"
        }
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/DepotStore.swift": "struct DepotStore {\n\(members)}",
        ])

        let output = try engine.strings(query: "MARKER")

        // Only the uppercase "MARKER…" literals match a case-sensitive query — the lowercase ones must not inflate the count.
        #expect(output.contains("+3 more — narrow the query"))
        #expect(!output.contains("marker0\""))
    }
}
