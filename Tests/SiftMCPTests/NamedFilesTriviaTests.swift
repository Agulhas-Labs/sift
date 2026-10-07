//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A name search of named Swift files is never answered with the name's `where`, whether a file spells the name in code alone or in trivia too.
@Suite(.temporaryDirectories)
struct NamedFilesTriviaTests {
    /// A package, built with an index store, whose `Ledger` names `settle` in code alone, whose `Journal` also names it in a doc comment, and whose `Quoted` also names it in a string literal.
    private static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Ledger.swift": "struct Ledger {\n    func settle() -> Int { 1 }\n    func close() -> Int { settle() }\n}\n",
            "Sources/App/Journal.swift": "/// Calls settle once the books close.\nstruct Journal {\n    func settle() -> Int { 2 }\n}\n",
            "Sources/App/Quoted.swift": "struct Quoted {\n    func settle() -> Int { 3 }\n    let label = \"settle\"\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// A name grep of named files is no candidate whether a file also names it in a doc comment or a string literal or spells it in code alone, so the search runs.
    @Test
    func aNameAlsoSpelledInTriviaIsWithheld() async throws {
        let root = try await Self.repository()
        let commands = [
            "grep -n settle Sources/App/Journal.swift", "grep -n settle Sources/App/Quoted.swift",
            "grep -n settle Sources/App/Ledger.swift Sources/App/Journal.swift", "grep -n settle Sources/App/Ledger.swift",
        ]

        for command in commands {
            #expect(InPlaceShape.match(forShell: command, in: root.path) == nil, "\(command)")
        }
    }
}
