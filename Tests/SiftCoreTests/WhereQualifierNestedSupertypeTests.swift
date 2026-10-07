//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A supertype the repository declares only as a nested type is one it may not declare at all.
@Suite(.temporaryDirectories)
struct WhereQualifierNestedSupertypeTests {
    /// Beside a nested type of the same name, a conformance written at the top level is to the framework's protocol, so a call inside an extension of a type the repository does not declare stays listed.
    @Test
    func aSupertypeOnlyANestedTypeSharesTheNameOfKeepsCallsInUnseenTypes() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            enum Shapes {
                struct Sendable {}
            }
            struct Depot: Sendable {
                func load(_ value: Int) {}
            }
            extension Array {
                func load(_ value: Int) {}
                func go() { load(1) }
            }
            struct Orchard {
                func load(_ value: Int) {}
                func tend() { load(2) }
            }
            """,
            to: "Sources/App/Types.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await CallSiteHeadingTests.lookup("Depot.load", in: root)

        #expect(output.contains("in Array.go()"), "\(output)")
        #expect(!output.contains("in Orchard.tend()"), "\(output)")
    }
}
