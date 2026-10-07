//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `strings` on wording a `+` builds from plain literals across lines, which no one literal holds.
@Suite(.temporaryDirectories)
struct StringsConcatenatedLiteralTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "concatenated literal fixture")
        return try SiftEngine(directory: root)
    }

    private static var productionStore: String {
        """
        struct DepotStore {
            func restock() -> String {
                "Restock refused — " +
                    "the build did " + // the reason follows
                    "not complete"
            }
        }
        """
    }

    private static var testStore: String {
        """
        import Testing

        struct DepotStoreTests {
            @Test
            func restock() {
                #expect(DepotStore().restock().hasSuffix("the build did not complete"))
            }
        }
        """
    }

    @Test
    func aRunJoinedByPlusIsListedAtTheFirstPieceTheMatchTouches() throws {
        let engine = try Self.makeRepo(files: [
            "Sources/Depot/DepotStore.swift": Self.productionStore,
            "Tests/Depot/DepotStoreTests.swift": Self.testStore,
        ])

        let output = try engine.strings(query: "did not complete")

        #expect(output.contains("  DepotStore.restock() — Sources/Depot/DepotStore.swift:4: \"the build did \" + \"not complete\""))
        #expect(output.contains("in tests: 1 site in 1 file — DepotStoreTests.swift (1)"))
        #expect(!output.contains("DepotStore.swift:3:"))
    }

    @Test
    func aRunSiteSortsAmongTheFilesOtherSitesByLine() throws {
        let store = """
        struct DepotStore {
            func restock() -> String {
                "the build did " +
                    "not complete"
            }

            func label() -> String {
                "did not complete"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": store])

        let lines = try engine.strings(query: "did not complete").split(separator: "\n").map(String.init)

        let run = try #require(lines.firstIndex { $0.contains("DepotStore.swift:3:") })
        let plain = try #require(lines.firstIndex { $0.contains("DepotStore.swift:8:") })

        #expect(run < plain)
    }

    @Test
    func aRunAPieceAlreadyHoldsIsListedOnceAsThatPiece() throws {
        let store = """
        struct DepotStore {
            func restock() -> String {
                "Restock did not " +
                    "complete — the build did not complete"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": store])

        let output = try engine.strings(query: "did not complete")

        #expect(output.contains("DepotStore.swift:4: \"complete — the build did not complete\""))
        #expect(!output.contains("\" + \""))
        #expect(!output.contains("DepotStore.swift:3:"))
    }

    @Test
    func aLongRunIsWindowedOnTheMatchAcrossItsPieces() throws {
        let filler = String(repeating: "orchard ", count: 12)
        let store = """
        struct DepotStore {
            func restock() -> String {
                "\(filler)the build did " +
                    "not complete \(filler)"
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": store])

        let output = try engine.strings(query: "did not complete")

        #expect(output.contains("DepotStore.swift:3: \"…"))
        #expect(output.contains("the build did \" + \"not complete"))
    }

    @Test
    func aLiteralAfterANestedOneOnItsLineStillJoins() throws {
        let store = """
        struct DepotStore {
            func restock(count: Int) -> [String] {
                ["shelf \\(String("gizmo")) \\(count)", "the build did " + "not complete"]
            }
        }
        """
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": store])

        let output = try engine.strings(query: "did not complete")

        #expect(output.contains("DepotStore.swift:3: \"the build did \" + \"not complete\""))
    }

    private static var unjoinedStores: [String] {
        [
            // Another operator spelled with `+`.
            """
            infix operator +++: AdditionPrecedence
            func +++ (lhs: String, rhs: String) -> String { lhs + rhs }
            struct DepotStore {
                func restock() -> String { "the build did " +++ "not complete" }
            }
            """,
            // Code between the pieces.
            """
            struct DepotStore {
                let label = "gizmo"
                func restock() -> String { "the build did " + label + "not complete" }
            }
            """,
            // An interpolated piece.
            """
            struct DepotStore {
                func restock(label: String) -> String { "the build \\(label) did " + "not complete" }
            }
            """,
            // A piece interpolated after the text the query needs.
            """
            struct DepotStore {
                func restock(label: String) -> String { "the build did " + "not complete\\(label)" }
            }
            """,
            // A multi-line literal piece.
            """
            struct DepotStore {
                func restock() -> String {
                    "the build did " + \"""
                    not complete
                    \"""
                }
            }
            """,
        ]
    }

    @Test(arguments: unjoinedStores)
    func literalsNoPlainPlusJoinsAreNotReadAsOne(store: String) throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/DepotStore.swift": store])

        let output = try engine.strings(query: "did not complete")

        #expect(!output.contains("\" + \""))
        #expect(output.contains("no Swift string literal contains it either"))
    }
}
