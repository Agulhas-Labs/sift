//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A `cat`/`less`/`head` of a whole file below `DigestFloor`'s own compression floor drew a `digest` refusal that cost more than the read it interrupted — `ShellAdvice` and `ReadAdvice` disagreeing about the identical file.
///
/// Kept apart from `ShellAdviceTests` rather than grown into it, which is already at its own length limit.
struct ShellAdviceFloorTests {
    /// Below the compression floor a whole-file read draws no nudge.
    ///
    /// `digest` hands back the source itself there, so the read got identical bytes and there was nothing a refusal could have saved — the exact shape of the issue: two files of 19 and 15 lines drew a `digest` refusal.
    @Test
    func aFileBelowTheCompressionFloorIsNotWorthInterrupting() {
        #expect(ShellAdvice.suggestion(
            for: "cat Sources/App/Provenance.swift",
            holdsSource: { _ in true },
            directory: "/repo",
            belowFloor: { _ in true }
        ) == nil)
    }

    /// The same file above the floor keeps its nudge — the exclusion is about size, not about the shape of the command.
    @Test
    func aFileAboveTheCompressionFloorKeepsItsNudge() throws {
        let suggestion = try #require(ShellAdvice.suggestion(
            for: "cat Sources/App/Provenance.swift",
            holdsSource: { _ in true },
            directory: "/repo",
            belowFloor: { _ in false }
        ))

        #expect(suggestion.call == "digest Provenance")
    }

    /// A read of several files drops the ones below the floor and keeps the ones above it.
    ///
    /// Where every named file is below it there is nothing left worth interrupting.
    @Test
    func aReadOfSeveralFilesDropsTheOnesBelowTheFloor() throws {
        #expect(ShellAdvice.suggestion(
            for: "cat Sources/App/Depot.swift Sources/App/Gizmo.swift",
            holdsSource: { _ in true },
            directory: "/repo",
            belowFloor: { _ in true }
        ) == nil)

        let suggestion = try #require(ShellAdvice.suggestion(
            for: "cat Sources/App/Depot.swift Sources/App/Gizmo.swift",
            holdsSource: { _ in true },
            directory: "/repo",
            belowFloor: { $0.hasSuffix("Depot.swift") }
        ))

        #expect(suggestion.call == "digest Gizmo")
    }

    /// A path with no `directory` to resolve it against keeps its nudge rather than dropping it.
    ///
    /// It cannot be judged, and the conservative direction — exactly `DigestFloor`'s own, for a file it cannot read at all — is to offer the call.
    @Test
    func aPathWithNoDirectoryToResolveAgainstKeepsItsNudge() throws {
        let suggestion = try #require(ShellAdvice.suggestion(
            for: "cat Sources/App/Provenance.swift",
            holdsSource: { _ in true },
            belowFloor: { _ in true }
        ))

        #expect(suggestion.call == "digest Provenance")
    }
}
