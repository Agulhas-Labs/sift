//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A grep of the whole repository is counted whatever git keeps in its own directory: git's binary index names every tracked file, and the grep Claude Code runs never descends into a version-control directory.
@Suite(.temporaryDirectories)
struct NamesSearchVcsTests {
    /// A repository declaring `Widget` in `Widget.swift`, so git's index holds the name, with two comment lines naming it in a file of another name.
    private static func repository() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Widget")
        try MCPTestRepo.add([
            "\(NoStoreSweepTests.shelf)/Stock.swift": NoStoreSweepTests.shop(using: "Widget") + "// A Widget is cheap.\n// Every Widget is sold.\n",
        ], to: root)
        _ = try await InPlaceAnswerTests.outcome("grep -rn Widget Sources", in: root)
        return root
    }

    /// The name is in git's binary index only because a tracked file is called by it; the root search is still counted.
    @Test
    func aTrackedFileNamedForTheNameLeavesARootSearchCounted() async throws {
        let root = try await Self.repository()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/App/Widget.swift").path))

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Widget .", in: root))

        #expect(answered.reason.contains("2 comment lines under . also match, not shown here"), "\(answered.reason)")
        #expect(!answered.reason.contains(ScopedGrepAnswerTests.notCounted), "\(answered.reason)")
    }

    /// A binary file of the working tree that holds the name is not a version-control file: the root search stays uncounted.
    @Test
    func aBinaryFileHoldingTheNameLeavesARootSearchUncounted() async throws {
        let root = try await Self.repository()
        try Data("Widget\0\u{1}\u{2}".utf8).write(to: root.appendingPathComponent("Sources/blob.dat"))

        let answered = try #require(try await InPlaceAnswerTests.answered("grep -rn Widget .", in: root))

        #expect(answered.reason.contains(ScopedGrepAnswerTests.notCounted + "\n"), "\(answered.reason)")
    }
}
