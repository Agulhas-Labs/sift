//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// `where --syntactic` answers from the source and writes nothing under `.sift/`, so a probe of a tree believed read-only leaves its index file as it was.
@Suite(.temporaryDirectories)
struct SyntacticWhereStoresNothingTests {
    /// An index already there goes stale (a Swift file edited since), which is when a query refreshing it would rewrite it: the database and its write-ahead log keep their size and modification time, and the answer still has the edit.
    @Test
    func aSyntacticWhereLeavesAnExistingIndexUntouched() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let depot = root.appendingPathComponent("Sources/App/Depot.swift")
        let edited = try String(contentsOf: depot, encoding: .utf8) + "\nstruct Restocked {}\n"
        try edited.write(to: depot, atomically: true, encoding: .utf8)
        let before = Self.fingerprint(of: root)

        let answer = try await WhereCommand.parse(["Restocked", "--syntactic", "--root", root.path]).answer()

        #expect(answer.contains("Restocked"), "\(answer)")
        #expect(answer.contains("stores nothing under this tree"), "\(answer)")
        #expect(!before.isEmpty, "the fixture has an index to leave alone")
        #expect(Self.fingerprint(of: root) == before)
    }

    /// On a fresh repository nothing under the tree is written, not even the `.sift/` entry in `.git/info/exclude` that opening an engine otherwise appends.
    @Test
    func aSyntacticWhereOnAFreshRepositoryWritesNothingUnderTheTree() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let exclude = root.appendingPathComponent(".git/info/exclude")
        let before = try? Data(contentsOf: exclude)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift").path))
        #expect(!(String(data: before ?? Data(), encoding: .utf8) ?? "").contains(".sift/"))

        let answer = try await WhereCommand.parse(["Alpha", "--syntactic", "--root", root.path]).answer()

        #expect(answer.contains("Alpha"), "\(answer)")
        #expect((try? Data(contentsOf: exclude)) == before, "the exclude file changed")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sift").path), "a .sift directory was created")
    }

    /// The size and modification time of the index database and of its write-ahead log, where a write lands first; the shared-memory file is left out, since SQLite touches it on any open of a database in WAL mode.
    private static func fingerprint(of root: URL) -> [String: String] {
        var found: [String: String] = [:]
        for name in ["index.db", "index.db-wal"] {
            let path = root.appendingPathComponent(".sift/\(name)").path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let size = attributes[.size] as? Int ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            found[name] = "\(size) \(modified)"
        }
        return found
    }
}
