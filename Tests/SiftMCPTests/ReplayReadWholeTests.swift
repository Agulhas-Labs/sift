//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The replay's `read whole` row, pinned where the whole digest can win: a repository whose `Package.swift` declares its module, so no module-guessed notice weighs on the whole digest and a window of all of a file is answered with it rather than with its members.
@Suite(.temporaryDirectories) struct ReplayReadWholeTests {
    /// A whole `Read` of a file a recovered window located with the file's own digest is read whole after that digest — counted on the `read whole` row and in the replayed share's denominator, never recovered.
    @Test func aWholeReadOfAFileARecoveredDigestLocatedIsReadWhole() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        // Bodies long enough that the file's digest is smaller than a window of all of it; the members a window of every line overlaps are the whole file, so they are no smaller than its digest.
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gizmo.swift": "/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n",
        ], to: root)
        try await SiftEngine(directory: root).ensureFresh()
        let gizmo = root.appendingPathComponent("Sources/App/Gizmo.swift").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 1,9999p Sources/App/Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Gizmo"),
            TranscriptAuditReplayTests.use("Read", input: ["file_path": gizmo], id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  cold            2  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  read whole      1  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  located         0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
    }
}
