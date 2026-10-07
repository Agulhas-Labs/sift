//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A whole-file digest of a tree that cannot be written still decides the floor for its file.
@Suite(.temporaryDirectories)
struct ReadOnlyVerdictTests {
    /// The digest's header, the in-memory note and the body, as `InPlaceAnswerer` and the CLI lay them out, read back for the file's verdict.
    @Test
    func aDigestCarryingTheInMemoryNoteStillYieldsItsFileVerdict() async throws {
        let root = try ReadOnlyTree.make()
        defer { ReadOnlyTree.restore(root) }
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let body = try engine.measuredDigest(targets: ["Sources/Depot.swift"], options: DigestOptions()).text
        let answer = freshness.headerLine + "\n" + body
        let lines = answer.split(separator: "\n").map(String.init)

        #expect(lines.dropFirst().first == SiftEngine.inMemoryIndexNote, "\(answer)")
        #expect(SourcePassthrough.fileVerdict(in: answer, of: "Sources/Depot.swift") != nil, "\(answer)")
        #expect(SourcePassthrough.fileVerdict(in: answer)?.path == "Sources/Depot.swift", "\(answer)")
    }
}
