//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers case-folded matching of `strings` against Swift string literals: a query matches whatever its case and the source's, since people type on-screen text in the case they remember.
@Suite(.temporaryDirectories)
struct StringsCaseFoldTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "case fold fixture")
        return try SiftEngine(directory: root)
    }

    @Test
    func anUppercaseQueryFindsBothAnUppercaseAndALowercaseLiteral() throws {
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
        #expect(output.contains("the request was refused"))
    }

    @Test
    func aMixedCaseQueryFindsAnUppercaseKicker() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/Kicker.swift":
                """
                struct Kicker {
                    let kicker = "WARNINGS"
                    let prose = "Many warnings"
                }
                """,
        ])

        let output = try engine.strings(query: "Warnings")

        #expect(output.contains("\"WARNINGS\""))
        #expect(output.contains("\"Many warnings\""))
        #expect(!output.contains("contains it either"))
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
    func theMoreCountAgreesWithTheRowsOfBothCases() throws {
        var members = ""
        for index in 0 ..< (SourceLiteralSearch.siteCap + 3) {
            members += "    let upper\(index) = \"MARKER\(index)\"\n"
            members += "    let lower\(index) = \"marker\(index)\"\n"
        }
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/DepotStore.swift": "struct DepotStore {\n\(members)}",
        ])

        let output = try engine.strings(query: "MARKER")

        // Both spellings match, so every literal counts: twice (siteCap + 3) sites, siteCap listed.
        #expect(output.contains("+\(SourceLiteralSearch.siteCap + 6) more — narrow the query"))
    }

    @Test
    func aMissStillSaysNoLiteralContainsIt() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/Kicker.swift": "struct Kicker {\n    let title = \"something else\"\n}\n",
        ])

        let output = try engine.strings(query: "Warnings")

        #expect(output.contains("no Swift string literal contains it either"))
    }
}
