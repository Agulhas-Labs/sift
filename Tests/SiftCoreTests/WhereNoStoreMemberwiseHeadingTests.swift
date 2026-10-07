//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep of a stored property counts its uses by name in one heading format, adds the memberwise label calls only where there are some, and never counts zero uses as a number.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseHeadingTests {
    private static func answer(_ symbol: String, declaring: String, using: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(declaring, to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write(using, to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    /// A property only ever passed by its label says it has no use by name, and its label calls stand alone rather than as an addition to nothing.
    @Test
    func aPropertyNeverReadByNameSaysNoUseByName() async throws {
        let output = try await Self.answer(
            "Gizmo.isReady",
            declaring: "struct Gizmo {\n    var isReady: Bool\n}\n",
            using: "func stock() -> Gizmo {\n    Gizmo(isReady: true)\n}\n\nfunc spare() -> Gizmo {\n    Gizmo(isReady: false)\n}\n"
        )

        #expect(output.contains("\"isReady\" (no use by name, 2 calls passing it as isReady: to the memberwise init, in 1 file):"), "\(output)")
        #expect(!output.contains("0 uses by name"), "\(output)")
        #expect(!output.contains("plus 2 calls"), "\(output)")
    }

    /// A struct whose labels cannot be worked out, with no use by name, counts that as no use rather than zero.
    @Test
    func unlistedLabelCallsWithNoUseByNameSayNoUseByName() async throws {
        let output = try await Self.answer(
            "Gizmo.isReady",
            declaring: "struct Gizmo {\n    var (weight, spare): (Int, Int)\n    var isReady: Bool\n}\n",
            using: "func stock() -> Gizmo {\n    Gizmo(weight: 1, spare: 2, isReady: true)\n}\n"
        )

        #expect(output.contains("nothing spelled \"isReady\" is listed here — no use by name, 1 call writing isReady: to Gizmo(…) not listed"), "\(output)")
    }

    /// A property with no label calls keeps the plain heading.
    @Test
    func aPropertyWithNoLabelCallsKeepsThePlainHeading() async throws {
        let output = try await Self.answer(
            "Gizmo.isReady",
            declaring: "struct Gizmo {\n    var isReady: Bool\n\n    init() {\n        isReady = false\n    }\n}\n",
            using: "func stock() -> Bool {\n    Gizmo().isReady\n}\n"
        )

        #expect(output.contains("\"isReady\" (2 uses in 2 files):"), "\(output)")
    }

    /// A private property written nowhere says so, with how the scan was narrowed, not that no call builds its type.
    @Test
    func aPrivatePropertyWrittenNowhereSaysSo() async throws {
        let output = try await Self.answer(
            "Gizmo.isReady",
            declaring: "struct Gizmo {\n    private var isReady = false\n}\n",
            using: "func stock() -> Gizmo {\n    Gizmo()\n}\n"
        )

        #expect(output.contains("no use spelled \"isReady\" anywhere in the working tree — narrowed to its declaring file, as it is private"), "\(output)")
        #expect(!output.contains("builds its type"), "\(output)")
    }
}
