//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Which stored properties a no-store `--refs` sweep reads as memberwise parameters, and which of those as defaulted, shown by whether a call leaving one out or passing it is listed as a label call of another property.
@Suite(.temporaryDirectories)
struct WhereNoStoreMemberwiseDefaultRuleTests {
    private static var omitting: String {
        "Gizmo(weight: 2, isReady: true)"
    }

    private static var passing: String {
        "Gizmo(weight: 3, extra: 1, isReady: true)"
    }

    private static let cases = [
        Case(declaration: "var extra: Int?", leavingItOutIsListed: true, passingItIsListed: true),
        Case(declaration: "var extra: Int!", leavingItOutIsListed: true, passingItIsListed: true),
        Case(declaration: "var extra: Optional<Int>", leavingItOutIsListed: true, passingItIsListed: true),
        Case(declaration: "var extra = 5", leavingItOutIsListed: true, passingItIsListed: true),
        Case(declaration: "var extra: Int", leavingItOutIsListed: false, passingItIsListed: true),
        Case(declaration: "let extra: Int?", leavingItOutIsListed: false, passingItIsListed: true),
        Case(declaration: "@State var extra: Int", leavingItOutIsListed: true, passingItIsListed: true),
        Case(declaration: "let extra = 5", leavingItOutIsListed: true, passingItIsListed: false),
        Case(declaration: "var extra: Int { 5 }", leavingItOutIsListed: true, passingItIsListed: false),
        Case(declaration: "static var extra = 5", leavingItOutIsListed: true, passingItIsListed: false),
    ]

    @Test(arguments: cases)
    func aPropertyIsAParameterOnlyWhereTheCompilerMakesItOne(_ rule: Case) async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Gizmo {\n    let weight: Int\n    \(rule.declaration)\n    var isReady: Bool\n}\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("func stock() {\n    _ = \(Self.omitting)\n    _ = \(Self.passing)\n}\n", to: "Sources/App/Depot.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: "Gizmo.isReady", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

        #expect(output.contains("| _ = \(Self.omitting)") == rule.leavingItOutIsListed, "\(rule.declaration)\n\(output)")
        #expect(output.contains("| _ = \(Self.passing)") == rule.passingItIsListed, "\(rule.declaration)\n\(output)")
    }
}

extension WhereNoStoreMemberwiseDefaultRuleTests {
    struct Case: CustomTestStringConvertible {
        let declaration: String
        /// Whether a call leaving the property out is a call of the memberwise init.
        let leavingItOutIsListed: Bool
        /// Whether a call passing the property by its label is a call of the memberwise init.
        let passingItIsListed: Bool

        var testDescription: String {
            declaration
        }
    }
}
