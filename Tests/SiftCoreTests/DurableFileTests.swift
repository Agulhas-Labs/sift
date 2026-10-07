//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the temp-file-then-rename mechanism shared by `SetAsideStore`, `TestDurationStore` and `ShardLedger`: a write lands whole, or not at all.
@Suite(.temporaryDirectories)
struct DurableFileTests {
    /// A successful write replaces the file with exactly what was passed, whichever mode wrote it.
    @Test(arguments: [true, false])
    func writesLandWhole(fsync: Bool) throws {
        let root = try TemporaryDirectory.make("durable-file")
        let url = root.appendingPathComponent("record.json")
        let data = Data(#"{"value":1}"#.utf8)

        try DurableFile.replace(url, with: data, fsync: fsync)

        #expect(try Data(contentsOf: url) == data)
    }

    /// The temporary is a stepping stone, not a leftover: once the rename lands, only the target's own name remains.
    @Test
    func noTemporaryLeftBehindOnSuccess() throws {
        let root = try TemporaryDirectory.make("durable-file")
        let url = root.appendingPathComponent("record.json")

        try DurableFile.replace(url, with: Data("first".utf8), fsync: true)

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)

        #expect(entries == ["record.json"])
    }

    /// A write that cannot land — the directory refuses new entries, so the temporary can never be created — leaves the old contents exactly as they were: the rename is the only commit point, so nothing before it may touch the target.
    @Test
    func aWriteThatCannotCreateTheTemporaryLeavesOldContentsIntact() throws {
        let root = try TemporaryDirectory.make("durable-file")
        let url = root.appendingPathComponent("record.json")
        let original = Data("original".utf8)
        try original.write(to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        #expect(throws: (any Error).self) {
            try DurableFile.replace(url, with: Data("replacement".utf8), fsync: false)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    /// A real interruption at the seam between the write and the rename — where a crash or a kill would actually land, whichever mode wrote the temporary — leaves the old contents exactly as they were and, with cleanup on failure left at its default, no temporary behind either: the rename is the only commit point, so nothing before it may touch the target, and a failure there leaves no trace of the attempt.
    @Test(arguments: [true, false])
    func anInterruptionBetweenWriteAndRenameLeavesOldContentsIntactAndNoTemporaryBehind(fsync: Bool) throws {
        struct Interruption: Error {}

        let root = try TemporaryDirectory.make("durable-file")
        let url = root.appendingPathComponent("record.json")
        let original = Data("original".utf8)
        try original.write(to: url)

        #expect(throws: Interruption.self) {
            try DurableFile.replace(url, with: Data("replacement".utf8), fsync: fsync) {
                throw Interruption()
            }
        }

        #expect(try Data(contentsOf: url) == original)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == ["record.json"])
    }

    /// The fsync path cleans up its temporary on failure too, matching what `replace`'s doc promises rather than stopping short of it: a stale entry already sitting at the exact temporary name — the shape a previous crashed attempt would leave — makes `createFile` fail before any of this run's bytes are written, and cleanup on failure, left at its default, clears it the same as it would a write or rename failure.
    @Test
    func anFsyncCreateFailureCleansUpTheTemporary() throws {
        let root = try TemporaryDirectory.make("durable-file")
        let url = root.appendingPathComponent("record.json")
        let original = Data("original".utf8)
        try original.write(to: url)
        let temporary = root.appendingPathComponent(".record.json.\(getpid()).tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)

        #expect(throws: DurableFileError.self) {
            try DurableFile.replace(url, with: Data("replacement".utf8), fsync: true)
        }

        #expect(try Data(contentsOf: url) == original)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == ["record.json"])
    }
}
