//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `--refs` sweep with no index store lists the lines a type writes its own name on inside its declaration and its extensions in its module, and the typealias declarations naming it, since a rename changes every one and nothing else in the answer lists them.
@Suite(.temporaryDirectories)
struct WhereNoStoreOwnLinesTests {
    private static func answer(_ symbol: String, files: [(path: String, source: String)], references: Bool = true) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for file in files {
            try TestSources.write(file.source, to: file.path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: references))
    }

    private static let declaring = (
        path: "Sources/App/Gizmo.swift",
        source: "struct Gizmo {\n    let weight: Int\n\n    static func light() -> Gizmo {\n        Gizmo(weight: 1)\n    }\n}\n\nextension Gizmo {\n    static let heavy = Gizmo(weight: 9)\n}\n\ntypealias Widget = Gizmo\n"
    )

    @Test
    func aConstructionInsideItsOwnExtensionIsListedInTheSweep() async throws {
        let using = (path: "Sources/App/Depot.swift", source: "func stock() -> Gizmo {\n    Gizmo(weight: 2)\n}\n")
        let output = try await Self.answer("Gizmo", files: [Self.declaring, using])

        #expect(output.contains("references: all sites by written name, paged by file"), "\(output)")
        #expect(output.contains("\"Gizmo\" used by 2 lines in 1 file"), "\(output)")
        #expect(output.contains("more lines inside its own declaration or its extensions in this module, which is not use, listed below as a rename changes them"), "\(output)")
        #expect(output.contains("1 more line declaring a typealias of it, which is another name for the type rather than use of it, listed below as a rename changes it"), "\(output)")
        #expect(output.contains("    :10  | static let heavy = Gizmo(weight: 9)"), "\(output)")
        #expect(output.contains("    :5  | Gizmo(weight: 1)"), "\(output)")
        #expect(output.contains("    :13  | typealias Widget = Gizmo"), "\(output)")
        #expect(output.contains("    :2  | Gizmo(weight: 2)"), "\(output)")
    }

    /// A type written only inside itself has no use, and its lines are still the ones a rename changes.
    @Test
    func aTypeWrittenOnlyInsideItselfStillListsThoseLines() async throws {
        let output = try await Self.answer("Gizmo", files: [Self.declaring])

        #expect(output.contains("no use spelled \"Gizmo\" anywhere"), "\(output)")
        #expect(output.contains("listed below as a rename changes them"), "\(output)")
        #expect(output.contains("    :10  | static let heavy = Gizmo(weight: 9)"), "\(output)")
    }

    /// Outside a sweep the lines stay counted as the type declaring itself, as the usage verdict has always read them.
    @Test
    func aPlainLookupStillCountsThemWithoutListingThem() async throws {
        let output = try await Self.answer("Gizmo", files: [Self.declaring], references: false)

        #expect(output.contains("inside its own declaration or its extensions in this module, which is not use"), "\(output)")
        #expect(!output.contains("listed below as a rename changes"), "\(output)")
        #expect(!output.contains(":10  | static let heavy = Gizmo(weight: 9)"), "\(output)")
    }
}
