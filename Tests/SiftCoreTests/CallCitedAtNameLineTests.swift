//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A call is cited at the line of the name it is made through, so a call ending a multi-line chain is read where it is written, not at the chain's first line.
@Suite(.temporaryDirectories)
struct CallCitedAtNameLineTests {
    private func sites(_ source: String, name: String) async throws -> [SyntacticCallSite] {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Chain.swift", in: root)
        let scanner = CallSiteScanner(repoRoot: root, enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()))
        return await scanner.callSites(named: [name: .call])[name] ?? []
    }

    @Test
    func aTwoLineChainCitesTheCalledMembersLine() async throws {
        let found = try await sites("func f() {\n    foo\n        .bar()\n}\n", name: "bar")

        #expect(found.map(\.line) == [3])
        #expect(found.first?.text == ".bar()")
    }

    @Test
    func aFourLineChainCitesEachCallAtItsOwnLine() async throws {
        let source = "func f() {\n    foo\n        .one()\n        .two()\n        .three()\n}\n"

        #expect(try await sites(source, name: "three").map(\.line) == [5])
        #expect(try await sites(source, name: "one").map(\.line) == [3])
    }

    @Test
    func aTrailingClosureCallCitesTheMembersLine() async throws {
        let found = try await sites("func f() {\n    foo\n        .bar {\n            1\n        }\n}\n", name: "bar")

        #expect(found.map(\.line) == [3])
    }

    @Test
    func aSingleLineCallKeepsItsLine() async throws {
        #expect(try await sites("func f() {\n    foo.bar()\n}\n", name: "bar").map(\.line) == [2])
    }
}
