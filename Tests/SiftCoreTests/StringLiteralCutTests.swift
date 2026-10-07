//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `StringsRenderer`'s display window for a source-literal line — a match kept visible however far into a long literal it sits.
@Suite(.temporaryDirectories)
struct StringLiteralCutTests {
    private static func makeRepo(files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "literal cut fixture")
        return try SiftEngine(directory: root)
    }

    /// A filler run of plain words, long enough on its own to push a following word past column 80.
    private static var filler: String {
        String(repeating: "orchard ", count: 16)
    }

    private static var farMatchStore: String {
        """
        struct Depot {
            func label() -> String {
                "\(filler)gizmo\(filler)"
            }
        }
        """
    }

    private static var nearMatchStore: String {
        """
        struct Depot {
            func label() -> String {
                "gizmo \(filler)"
            }
        }
        """
    }

    private static var shortStore: String {
        """
        struct Depot {
            func label() -> String {
                "a short gizmo"
            }
        }
        """
    }

    @Test
    func aMatchPastColumnEightyKeepsTheMatchVisibleWithALeadingEllipsis() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/Depot.swift": Self.farMatchStore])

        let output = try engine.strings(query: "gizmo")
        let literalLine = output.split(separator: "\n").first { $0.contains("Depot.swift:3") }

        let line = try #require(literalLine)

        #expect(line.contains("gizmo"))
        #expect(line.contains("…"))
        // The very first word of the literal sat well before the match; trimming it off is the point.
        #expect(!line.contains("\"orchard orchard orchard"))
    }

    @Test
    func aMatchNearTheStartRendersWithTheLeadingTextIntact() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/Depot.swift": Self.nearMatchStore])

        let output = try engine.strings(query: "gizmo")
        let literalLine = output.split(separator: "\n").first { $0.contains("Depot.swift:3") }

        let line = try #require(literalLine)

        #expect(line.contains("\"gizmo "))
        #expect(line.contains("…"))
    }

    @Test
    func aShortLiteralRendersWholeWithNoEllipsis() throws {
        let engine = try Self.makeRepo(files: ["Sources/Depot/Depot.swift": Self.shortStore])

        let output = try engine.strings(query: "gizmo")
        let literalLine = output.split(separator: "\n").first { $0.contains("Depot.swift:3") }

        let line = try #require(literalLine)

        #expect(line.contains("\"a short gizmo\""))
        #expect(!line.contains("…"))
    }
}
