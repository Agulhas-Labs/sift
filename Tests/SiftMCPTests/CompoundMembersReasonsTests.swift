//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A members answer on a line of several files says every reason a whole digest was set aside: one file's, already set aside for its window's members, beside the one the whole answer was set aside for, each once.
@Suite(.temporaryDirectories)
struct CompoundMembersReasonsTests {
    /// The opening line of the answer to `line` in a repository holding `Outer`, whose digest names a nested type's members without their lines, and `Thing`, below whose imports a window's members are smaller than the whole digest.
    private static func openingLine(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let root = try await CompoundSetAsideReasonTests.repository(small: CompoundSetAsideReasonTests.smalls[0])
        try WindowMembersPlacedTests.outer.joined(separator: "\n").write(to: root.appendingPathComponent("Sources/App/Outer.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: line, in: root.path), sourceLocation: sourceLocation)
        let outcome = try await CompoundSetAsideReasonTests.outcome(match)
        guard case let .answered(answered) = outcome else { return "\(outcome)" }
        return String(answered.reason.prefix { $0 != "\n" })
    }

    /// Where the members answer wins over whole digests it is smaller than, its note keeps the reason `Outer`'s digest was set aside, beside its own.
    @Test
    func theMembersAnswerKeepsTheReasonAnotherFilesDigestWasSetAside() async throws {
        let opening = try await Self.openingLine("sed -n 85,104p Sources/App/Outer.swift; sed -n 44,74p Sources/App/Imports.swift")

        #expect(opening.contains("are shown; the whole digest names some of them without their lines or the whole digest is larger than they are)"), "\(opening)")
    }
}
