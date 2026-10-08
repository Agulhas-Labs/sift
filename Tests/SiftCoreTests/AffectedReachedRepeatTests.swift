//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `affected --reached` repeats: the answer carries one `reached?` block per name, in the order given, and none is dropped.
@Suite(.temporaryDirectories)
struct AffectedReachedRepeatTests {
    private static func answers(probes: [[String]]) async throws -> [String] {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"Lib\",\n    targets: [\n        .target(name: \"Lib\"),\n        .testTarget(name: \"LibTests\", dependencies: [\"Lib\"]),\n    ]\n)\n", to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write("import Testing\n@testable import Lib\n\nstruct AlphaTests {\n    @Test func uses() { _ = Widget() }\n}\n", to: "Tests/LibTests/AlphaTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        var outputs: [String] = []
        for names in probes {
            try await outputs.append(engine.affected(options: AffectedOptions(probes: names), freshness: freshness))
        }
        return outputs
    }

    private static func blocks(in answer: String) -> [String] {
        answer.split(separator: "\n").filter { $0.hasPrefix("reached? ") }.map { String($0.prefix { $0 != "—" }.dropLast()) }
    }

    /// Every name gets its block, in the order given, and a name given twice gets one.
    @Test
    func eachNameGetsABlockInTheOrderGiven() async throws {
        let outputs = try await Self.answers(probes: [
            ["LibTests.GizmoTests", "LibTests.AlphaTests/uses()", "LibTests.BetaTests"],
            ["LibTests.GizmoTests", "LibTests.GizmoTests"],
        ])

        #expect(Self.blocks(in: outputs[0]) == ["reached? LibTests.GizmoTests", "reached? LibTests.AlphaTests/uses()", "reached? LibTests.BetaTests"])
        #expect(Self.blocks(in: outputs[1]) == ["reached? LibTests.GizmoTests"])
    }

    /// One name prints what it always did: a longer list only appends blocks after the single name's lines.
    @Test
    func aSingleNameAnswersAsItAlwaysDid() async throws {
        let outputs = try await Self.answers(probes: [["LibTests.GizmoTests"], ["LibTests.GizmoTests", "LibTests.BetaTests"]])

        #expect(outputs[1].hasPrefix(outputs[0]))
    }
}
