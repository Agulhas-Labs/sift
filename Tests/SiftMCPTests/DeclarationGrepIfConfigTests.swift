//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A member inside `#if` is listed by its digest with the condition after its range, and is as located by that entry as any other member is.
@Suite(.temporaryDirectories)
struct DeclarationGrepIfConfigTests {
    /// The digest line `func debug()  :N  [#if DEBUG]` accounts for the line the grep prints, so the search of a file with such a member is answered with the digest.
    @Test
    func aMemberInsideAnIfConfigIsLocatedByItsSuffixedEntry() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let fillers = (0 ..< 40).flatMap { index in
            ["    func stock\(index)() -> Int {", "        let count = \(index)", "        let doubled = count * 2", "        return doubled + count", "    }"]
        }
        let lines = ["struct Gated {", "    func first() {}", "    #if DEBUG", "    func debug() {}", "    #endif"] + fillers + ["}"]
        try MCPTestRepo.add(["Sources/App/Gated.swift": lines.joined(separator: "\n") + "\n"], to: root)
        try await SiftEngine(directory: root).ensureFresh()

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -n 'func ' Sources/App/Gated.swift", in: root))

        #expect(answered.calls.map(\.target) == ["Sources/App/Gated.swift"])
    }
}
