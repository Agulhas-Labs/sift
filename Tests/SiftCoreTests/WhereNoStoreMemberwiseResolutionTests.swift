//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A no-store `--refs` sweep of a stored property lists the calls passing it by its label to its struct's memberwise initializer only where they are that initializer's, and says what it left out and why.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseResolutionTests {
    private static func answer(_ symbol: String, files: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
    }

    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "App",
            targets: [.target(name: "App", dependencies: ["Lib"]), .target(name: "Lib")]
        )
        """
    }

    private static func position(of text: String, in output: String) -> String.Index? {
        output.range(of: text)?.lowerBound
    }

    /// A call passing the label and a use by name in one file are listed in line order, whichever list each came from.
    @Test
    func aFilesRowsAscendByLineAcrossUsesAndLabelCalls() async throws {
        let output = try await Self.answer("Gizmo.isReady", files: [
            "Sources/App/Gizmo.swift": "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n",
            "Sources/App/Depot.swift": "func stock() -> Bool {\n    let gizmo = Gizmo(weight: 2, isReady: true)\n    return gizmo.isReady\n}\n",
        ])
        let call = Self.position(of: ":2  in stock().gizmo  | let gizmo = Gizmo(weight: 2, isReady: true)", in: output)
        let use = Self.position(of: ":3  in stock()  | return gizmo.isReady", in: output)
        let both = try #require(call.flatMap { call in use.map { (call, $0) } }, "\(output)")

        #expect(both.0 < both.1, "\(output)")
    }

    /// A call that may build a same-named type is flagged and counted apart, and one leaving out a parameter with no default is counted and not listed, whichever type the index reads its qualifier as.
    @Test
    func aCallOfASameNamedTypeIsToldApartFromTheMemberwiseInit() async throws {
        let output = try await Self.answer("App.Gizmo.isReady", files: [
            "Package.swift": Self.manifest,
            "Sources/App/Gizmo.swift": "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n",
            "Sources/App/Box.swift": "struct Box {\n    struct Gizmo {\n        var isReady: Bool\n    }\n\n    let inner = Gizmo(isReady: true)\n}\n",
            "Sources/Lib/Gizmo.swift": "public final class Gizmo {\n    public init(weight: Int, isReady: Bool) {}\n}\n\nlet spare = Gizmo(weight: 7, isReady: true)\n",
            "Sources/App/Depot.swift": "func stock() -> Bool {\n    let gizmo = App.Gizmo(weight: 2, isReady: true)\n    let boxed = Box.Gizmo(isReady: false)\n    return gizmo.isReady && boxed.isReady\n}\n",
        ])

        #expect(output.contains("plus 1 call passing it as isReady: to the memberwise init, 1 more writing isReady: to Gizmo(…) that may build another type named Gizmo, flagged, 2 writing isReady: to Gizmo(…) with labels its memberwise init does not take, not listed"), "\(output)")
        #expect(output.contains(":2  in stock().gizmo  | let gizmo = App.Gizmo(weight: 2, isReady: true)"), "\(output)")
        #expect(output.contains(":5  in spare (builds App.Gizmo or Lib.Gizmo — nothing written tells which)  | let spare = Gizmo(weight: 7, isReady: true)"), "\(output)")
        #expect(!output.contains("let inner = Gizmo(isReady: true)"), "\(output)")
        #expect(!output.contains("let boxed = Box.Gizmo(isReady: false)"), "\(output)")
    }

    /// A parameter is required only where its declaration, read whole, has no initial value: one cut from a long signature still makes its property no parameter.
    @Test
    func aParameterWithoutADefaultMustBeSupplied() async throws {
        let required = try await Self.answer("Gizmo.isReady", files: [
            "Sources/App/Gizmo.swift": "struct Gizmo {\n    let weight: Int\n    var isReady: Bool\n}\n",
            "Sources/App/Depot.swift": "func stock() -> Gizmo {\n    Gizmo(isReady: true)\n}\n",
        ])
        let long = try await Self.answer("Gizmo.isReady", files: [
            "Sources/App/Gizmo.swift": "struct Gizmo {\n    let weight: Int = Int(\"4096\", radix: 16).map { $0 / 2 } ?? 1_024_000\n    var isReady: Bool\n}\n",
            "Sources/App/Depot.swift": "func stock() -> Gizmo {\n    Gizmo(isReady: true)\n}\n",
        ])

        #expect(required.contains("no use by name, 1 call writing isReady: to Gizmo(…) with labels its memberwise init does not take, not listed"), "\(required)")
        #expect(!required.contains("| Gizmo(isReady: true)"), "\(required)")
        #expect(long.contains("no use by name, 1 call passing it as isReady: to the memberwise init"), "\(long)")
        #expect(long.contains(":2  in stock()  | Gizmo(isReady: true)"), "\(long)")
    }
}
