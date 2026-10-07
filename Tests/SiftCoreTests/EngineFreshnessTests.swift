//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the freshness contract end to end against real git repos (Docs/Design.md §2 and §7).
@Suite(.temporaryDirectories)
struct EngineFreshnessTests {
    @Test
    func firstQueryBuildsAndAnswers() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 0)
        #expect(digest.contains("struct Alpha"))
    }

    @Test
    func plainCommitMovesHeadWithoutRefusalOrError() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("not swift\n", to: "notes.txt", in: root)
        try TestSources.commitAll(in: root, message: "notes only")

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 0)
        #expect(digest.contains("struct Alpha"))
    }

    @Test
    func dirtyEditIsReparsedBeforeAnswering() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("struct Alpha { let one = 1\n    func added() {} }\n", to: "Sources/App/Alpha.swift", in: root)

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 1)
        #expect(digest.contains("func added()"))
    }

    @Test
    func headMoveWithCleanTreeReparsesExactlyTheRangeDiff() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        // Edit + commit in one stride: the tree is clean when the engine next looks, only HEAD moved.
        try TestSources.write("struct Alpha { let one = 1\n    func pulled() {} }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "simulate a pull")

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 0)
        #expect(digest.contains("func pulled()"))
    }

    @Test
    func renameMovesTheIndexedPath() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["mv", "Sources/App/Alpha.swift", "Sources/App/Renamed.swift"], in: root)

        _ = try await engine.ensureFresh()
        let newPath = try engine.digest(target: "Sources/App/Renamed.swift", options: DigestOptions())
        let oldPath = try engine.digest(target: "Sources/App/Alpha.swift", options: DigestOptions())

        #expect(newPath.contains("struct Alpha"))
        #expect(oldPath.contains("no indexed file"))
    }

    @Test
    func revertedFileHealsBackToHeadContent() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("struct Alpha { let one = 1\n    func ghost() {} }\n", to: "Sources/App/Alpha.swift", in: root)
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["checkout", "--", "Sources/App/Alpha.swift"], in: root)

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Alpha", options: DigestOptions())

        #expect(freshness.dirtyCount == 0)
        #expect(!digest.contains("func ghost()"))
    }

    @Test
    func nonASCIIPathsIndexAndUpdate() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Café { let brew = 1 }\n", to: "Sources/App/Café.swift", in: root)
        try TestSources.commitAll(in: root, message: "add café")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let first = try engine.digest(target: "Café", options: DigestOptions())
        try TestSources.write("struct Café { let brew = 1\n    func refill() {} }\n", to: "Sources/App/Café.swift", in: root)

        _ = try await engine.ensureFresh()
        let second = try engine.digest(target: "Café", options: DigestOptions())

        #expect(first.contains("struct Café"))
        #expect(second.contains("func refill()"))
    }

    @Test
    func unbornRepoAnswersBeforeItsFirstCommit() async throws {
        let root = try TemporaryDirectory.make("unborn")
        try TestSources.runGit(["init", "-b", "main"], in: root)
        try TestSources.write("struct Nascent {}\n", to: "Sources/App/Nascent.swift", in: root)
        let engine = try SiftEngine(directory: root.resolvingSymlinksInPath())

        let freshness = try await engine.ensureFresh()
        let digest = try engine.digest(target: "Nascent", options: DigestOptions())

        #expect(freshness.headShort == "unborn")
        #expect(digest.contains("struct Nascent"))
    }

    @Test
    func gitignoredFilesStayOutsideTheIndex() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("Generated/\n", to: ".gitignore", in: root)
        try TestSources.write("struct Alpha {}\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.write("struct Phantom {}\n", to: "Generated/Phantom.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed with ignore")
        let engine = try SiftEngine(directory: root)

        _ = try await engine.ensureFresh()
        let phantom = try engine.digest(target: "Phantom", options: DigestOptions())

        #expect(phantom.contains("no symbol named Phantom") || phantom.contains("nearest symbols"))
    }

    @Test
    func standingDirtyFileIsNotReparsedEveryQuery() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha { let one = 1 }\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "add alpha")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("struct Alpha { let one = 2 }\n", to: "Sources/App/Alpha.swift", in: root)
        _ = try await engine.ensureFresh()
        let countAfterDirtyParse = try engine.store.metaValue("incremental_count")

        _ = try await engine.ensureFresh()
        _ = try await engine.ensureFresh()
        let countAfterRepeatQueries = try engine.store.metaValue("incremental_count")

        #expect(countAfterDirtyParse != nil)
        #expect(countAfterRepeatQueries == countAfterDirtyParse)
    }

    @Test
    func configEditsAreLiveMidSession() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/App/Alpha.swift", in: root)
        try TestSources.write("struct Extra {}\n", to: "Extras/Extra.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let before = try engine.digest(target: "Extra", options: DigestOptions())
        try TestSources.write("{\n  \"exclude\": [\"Extras/\"]\n}\n", to: ".sift.json", in: root)

        _ = try await engine.ensureFresh()
        _ = try await engine.fullIndex()
        let after = try engine.digest(target: "Extra", options: DigestOptions())

        #expect(before.contains("struct Extra"))
        #expect(after.contains("no symbol named Extra") || after.contains("nearest symbols"))
    }

    @Test
    func parseErrorsSurfaceInTheHeader() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Broken {\n    let dangling =\n", to: "Sources/App/Broken.swift", in: root)
        try TestSources.commitAll(in: root, message: "broken")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()

        #expect(freshness.parseErrorFiles == 1)
        #expect(freshness.headerLine.contains("parse_errors: 1"))
    }

    /// A tracked symbolic link to a Swift file is never indexed under its own path, because git reports an edit to the target and never one to the link, so the link's rows would go on citing lines the file no longer has.
    @Test
    func aSymbolicLinkIsAnsweredOnlyThroughTheFileItPointsTo() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum Drum {\n    static func stock() -> Int {\n        1\n    }\n}\n", to: "Sources/Links/Drum.swift", in: root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Sources/Links/Link.swift").path, withDestinationPath: "Drum.swift")
        try TestSources.commitAll(in: root, message: "drum and a link to it")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        try TestSources.write("// one\n// two\nenum Drum {\n    static func stock() -> Int {\n        1\n    }\n}\n", to: "Sources/Links/Drum.swift", in: root)

        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Drum.stock", freshness: freshness)

        #expect(freshness.dirtyCount == 1)
        #expect(answer.contains("Sources/Links/Drum.swift:4-6"))
        #expect(!answer.contains("Link.swift"))
        #expect(try engine.store.fileRow(path: "Sources/Links/Link.swift") == nil)
    }

    /// A committed file replaced by a symbolic link loses its rows on the next query, rather than waiting for a reconcile to notice the path is no longer indexable.
    @Test
    func aFileReplacedByASymbolicLinkLosesItsRows() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum Drum {\n    static func stock() -> Int {\n        1\n    }\n}\n", to: "Sources/Links/Drum.swift", in: root)
        try TestSources.write("enum Kick {\n    static func stock() -> Int {\n        2\n    }\n}\n", to: "Sources/Links/Link.swift", in: root)
        try TestSources.commitAll(in: root, message: "drum and kick")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let link = root.appendingPathComponent("Sources/Links/Link.swift").path
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "Drum.swift")

        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Kick.stock", freshness: freshness)

        #expect(freshness.dirtyCount == 1)
        #expect(try engine.store.fileRow(path: "Sources/Links/Link.swift") == nil)
        #expect(!answer.contains("Link.swift"))
    }
}
