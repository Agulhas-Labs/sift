//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A build manifest is not Swift *source* to this tool — the index deliberately excludes it — so no advice layer may refuse reading one, and no measurement may score that read as a lookup the index lost.
///
/// The dead end this pins: refusing `Read(Package.swift)` with "digest Package", a suggestion that can never resolve because the index stores no manifest and the manifest declares no type named Package.
struct ManifestExclusionTests {
    @Test
    func aManifestReadGetsNoAdvice() {
        let manifest = ReadAdvice.suggestion(path: "/repo/VendorTools/Package.swift", ranged: false, belowFloor: { _ in false })
        let source = ReadAdvice.suggestion(path: "/repo/Sources/App/Alpha.swift", ranged: false, belowFloor: { _ in false })

        #expect(manifest == nil)
        #expect(source != nil)
    }

    @Test
    func aVersionedManifestReadGetsNoAdviceEither() {
        let versioned = ReadAdvice.suggestion(path: "/repo/Package@swift-6.0.swift", ranged: false, belowFloor: { _ in false })

        #expect(versioned == nil)
    }

    @Test
    func aShellReadOfAManifestIsNotALookup() {
        let manifest = ShellAdvice.suggestion(for: "cat VendorTools/Package.swift")
        let source = ShellAdvice.suggestion(for: "cat Sources/App/Alpha.swift")

        #expect(manifest == nil)
        #expect(source != nil)
    }

    @Test
    func aGrepInsideAManifestIsNotALookup() {
        let manifest = SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "targets", "path": "/repo/VendorTools/Package.swift"])
        let source = SearchToolAdvice.suggestion(tool: "Grep", input: ["pattern": "targets", "path": "/repo/Sources/App/Alpha.swift"])

        #expect(manifest == nil)
        #expect(source != nil)
    }

    /// The statusline share must not count a manifest read as a raw Swift read — the index will never serve that file, so the read cannot be a miss.
    @Test
    func theStatuslineDoesNotCountAManifestRead() {
        var state = TranscriptScanState()
        let line: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/repo/Package.swift"]]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()

        let events = TranscriptScan.events(line: data, state: &state)

        #expect(events.isEmpty)
    }
}
