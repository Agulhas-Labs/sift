//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A `sift digest` run from the shell locates the file it names, as the MCP digest does, so the window that follows it is the loop working at the scan as it already is at the advice hook.
struct ShellDigestLocationTests {
    /// The disagreement this closes: the hook's ledger holds a shell digest's target as digested and lets the window after it through, while the scan credited nothing and counted that window cold.
    @Test(arguments: [
        TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n '40,60p' Sources/App/RecordDetailView.swift"]),
        TranscriptFixture.toolUse("Read", id: "w1", input: ["file_path": "Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
    ])
    func aWindowOfAFileAShellDigestNamedIsGuided(window: Data) {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "cd /repo && sift digest Sources/App/RecordDetailView.swift"]),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "Sources/App/RecordDetailView.swift — module: App\nstruct RecordDetailView: View  :12-80"),
            window,
        ])

        #expect(lookups == [.indexed, .guided(file: "Sources/App/RecordDetailView.swift")])
    }

    /// A type target locates its file too, and each of several targets is credited, as the MCP call's `targets` are.
    @Test
    func everyTypeAShellDigestNamedIsLocated() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest DepotCatalog RecordDetailView"]),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "RecordDetailView — App — Sources/App/RecordDetailView.swift:12-80"),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/RecordDetailView.swift", "offset": 40, "limit": 20]),
        ])

        #expect(lookups == [.indexed, .guided(file: "/repo/Sources/App/RecordDetailView.swift")])
    }

    /// A whole read after a shell digest is the read the digest exists to save, which the hook lets through as already digested.
    @Test
    func aWholeReadAfterAShellDigestIsReadWholeAfterItsDigest() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest DepotCatalog"]),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "DepotCatalog — App — DepotCatalog.swift:8-90"),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/DepotCatalog.swift"]),
        ])

        #expect(lookups == [.indexed, .readWholeAfterDigest(file: "/repo/DepotCatalog.swift")])
    }

    /// A shell line that errored located nothing the scan can vouch for, so the window after it stays a miss, and the line is no index failure either — nor is it counted as indexed, since the error may belong to another command sharing the line, not the digest itself.
    @Test
    func aShellDigestWhoseLineFailedLocatesNothing() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest RecordDetailView && swift build"]),
            TranscriptFixture.toolResult(id: "b1", isError: true, text: "error: build failed"),
            TranscriptFixture.toolUse("Bash", id: "w1", input: ["command": "sed -n '40,60p' Sources/App/RecordDetailView.swift"]),
        ])

        #expect(tally.cold == 1)
        #expect(tally.guided == 0)
        #expect(tally.indexed == 0)
        #expect(tally.failed == 0)
    }

    /// The disagreement the fix closes: a solo errored Bash `sift digest` counted as indexed even though it served nothing, while the identical call that succeeds still counts once — on the CLI, not the server.
    @Test
    func anErroredBashDigestIsNotIndexedButASuccessfulOneIs() {
        let failedTally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest Foo"]),
            TranscriptFixture.toolResult(id: "b1", isError: true, text: "error: no repository is indexed at that root"),
        ])
        #expect(failedTally.indexed == 0)
        #expect(failedTally.cliServed == 0)
        #expect(failedTally.failed == 0)

        let succeededTally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b2", input: ["command": "sift digest Foo"]),
            TranscriptFixture.toolResult(id: "b2", isError: false, text: "struct Foo  :8-20"),
        ])
        #expect(succeededTally.indexed == 1)
        #expect(succeededTally.cliServed == 1)
    }

    /// A window on the digest's own line was chosen before its answer came back, so it is cold, as a ranged read beside an MCP digest in one turn would be.
    @Test
    func aWindowOnTheDigestsOwnLineIsStillCold() {
        let lookups = TranscriptFixture.lookups([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift digest RecordDetailView; sed -n '40,60p' Sources/App/RecordDetailView.swift"]),
            TranscriptFixture.toolResult(id: "b1", isError: false, text: "struct RecordDetailView: View  :12-80"),
        ])

        #expect(lookups == [.indexed, .cold(file: "Sources/App/RecordDetailView.swift", missed: nil)])
    }
}
