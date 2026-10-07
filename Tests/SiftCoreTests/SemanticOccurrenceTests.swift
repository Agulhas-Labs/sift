//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the half of the semantic axis that looks at the files an answer *cites*, not the file it is about.
///
/// The index store holds every occurrence the last build compiled, so a file deleted or edited afterwards leaves rows behind that the git head, the dirty set, and the declaring file's mtime all agree are fine.
@Suite(.temporaryDirectories)
struct SemanticOccurrenceTests {
    /// A buildable package whose caller lives in its own file, so deleting the caller does not delete the declaration with it.
    private static func makeRepoWithDeletableCaller() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public struct Widget {
                public init() {}
            }

            public func helper() {}
            """,
            to: "Sources/Lib/Core.swift",
            in: root
        )
        try TestSources.write(
            """
            public func callsHelper() {
                helper()
                _ = Widget()
            }
            """,
            to: "Sources/Lib/Extra.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "deletable caller fixture")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    /// The reproduction: `git rm` a caller, commit, and the store still holds its occurrences.
    ///
    /// Both existing axes are satisfied — the head matches, the tree is clean, and the *declaring* file was never touched — so on those axes alone the answer goes out under `semantic: fresh` naming a caller in a file that no longer exists.
    @Test
    func aCallerInADeletedFileIsNeverServedAsLive() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["rm", "Sources/Lib/Extra.swift"], in: root)
        try TestSources.commitAll(in: root, message: "delete the caller")

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(output.contains("Sources/Lib/Extra.swift"))
        #expect(output.contains("(file deleted since last build)"))
        #expect(output.contains("semantic: stale (1 occurrence file deleted since last build)"))
        #expect(!output.contains("semantic: fresh"))
    }

    /// The half a blanket refusal would have destroyed, and the reason this labels rather than refuses.
    ///
    /// A deletion sweep reads `where --refs` *after* the delete precisely to separate a reference it has just orphaned from one that was already dead. Refusing the symbol answers that question with silence.
    @Test
    func aDeleteSweepStillSeesTheOrphanItJustCreated() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["rm", "Sources/Lib/Extra.swift"], in: root)
        try TestSources.commitAll(in: root, message: "delete the caller")

        let freshness = try await engine.ensureFresh()
        let swept = try await engine.lookup(symbol: "Widget", freshness: freshness, options: WhereOptions(includeReferences: true))

        // The row survives, so the sweep can still be run; it simply no longer passes for live.
        #expect(swept.contains("Sources/Lib/Extra.swift"))
        #expect(swept.contains("(file deleted since last build)"))
        #expect(swept.contains("1 file deleted since last build"))
        #expect(!swept.contains("semantic: fresh"))
    }

    /// Surviving occurrences keep answering beside the dead one — the refusal shape would have taken them with it.
    @Test
    func occurrencesInSurvivingFilesStillAnswerBesideADeletedOne() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        try TestSources.write(
            """
            public func alsoCallsHelper() {
                helper()
            }
            """,
            to: "Sources/Lib/Second.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "a second caller")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.runGit(["rm", "Sources/Lib/Extra.swift"], in: root)
        try TestSources.commitAll(in: root, message: "delete one of the two callers")

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(output.contains("callers of Lib.helper() (2, 1 file deleted since last build):"))
        // The live row sorts first, so a truncated section never spends its cap on rows already known dead.
        let all = output.split(separator: "\n").map(String.init)
        let heading = try #require(all.firstIndex { $0.hasPrefix("callers of Lib.helper() (") })
        let rows = all[(heading + 1)...].prefix { $0.hasPrefix("  ") }
        let files = rows.filter { !$0.hasPrefix("    ") }
        #expect(rows.count == 4, "\(output)")
        #expect(files.first?.contains("Second.swift") == true)
        #expect(files.first?.contains("since last build") == false)
        #expect(files.last?.contains("Extra.swift") == true)
        #expect(files.last?.contains("(file deleted since last build)") == true)
        // A deleted file's line cannot be read, so its row carries no text.
        #expect(rows.last?.contains("  | ") == false, "\(output)")
    }

    /// The other end of the same hole: the file is still there, but it has been written since the build, so the line the store names may have moved.
    ///
    /// The declaring-file check never sees this — `helper()`'s own file is untouched — so on that check alone the answer goes out `fresh` pointing at a line number nothing has re-derived.
    @Test
    func anOccurrenceInAFileEditedSinceTheBuildIsLabelledToo() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(
            """
            // a line the build never saw
            public func callsHelper() {
                helper()
                _ = Widget()
            }
            """,
            to: "Sources/Lib/Extra.swift",
            in: root
        )

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(output.contains("(file changed since last build)"))
        #expect(output.contains("semantic: stale (1 file changed since last build)"))
        #expect(!output.contains("semantic: fresh"))
    }

    /// Nothing deleted, nothing edited: the answer must read exactly as it did, or the check has made every clean query worse.
    @Test
    func aCleanTreeStillAnswersFreshWithNoLabels() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "helper()", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(output.contains("semantic: fresh"))
        #expect(output.contains("callers of Lib.helper() (1):"))
        #expect(!output.contains("since last build)"))
    }

    // MARK: The sweep's own edits must not move the page cursor

    /// A package with more referencing files than one page holds, so `--refs` genuinely pages.
    private static func makeRepoWithManyReferencingFiles(count: Int) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        // The declaring file is never touched, so the sweep answers instead of refusing.
        try TestSources.write("public struct Marker {\n    public init() {}\n}\n", to: "Sources/Lib/Marker.swift", in: root)
        for index in 0 ..< count {
            let name = String(format: "Use%03d", index)
            try TestSources.write("public func use\(index)() {\n    _ = Marker()\n}\n", to: "Sources/Lib/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "many referencing files")
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    private static func listedFiles(in output: String) -> [String] {
        output
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line in
                guard line.hasPrefix("  Sources/Lib/"), let paren = line.range(of: " (") else { return nil }
                return String(line[line.startIndex ..< paren.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
    }

    /// The cursor must survive the sweep editing the files the sweep just served.
    ///
    /// Ordering live rows first is a display choice, and liveness moves under the reader's own hand: edit page one and those files leave the live group. A cursor keyed to that order then steps over as many files as moved — never listing them, never saying so, in exactly the multi-page sweep the paging exists for.
    @Test
    func editingPageOneDoesNotDropFilesFromPageTwo() async throws {
        let total = WhereRenderer.listCap + 5
        let root = try Self.makeRepoWithManyReferencingFiles(count: total)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        var freshness = try await engine.ensureFresh()
        let firstPage = try await engine.lookup(symbol: "Marker", freshness: freshness, options: WhereOptions(includeReferences: true))

        // The sweep does its work: every file page one served is edited, which is what changes their liveness.
        for name in Self.listedFiles(in: firstPage) {
            let index = try #require(Int(name.dropFirst("Sources/Lib/Use".count).prefix(3)))
            try TestSources.write("// swept\npublic func use\(index)() {\n    _ = Marker()\n}\n", to: name, in: root)
        }
        freshness = try await engine.ensureFresh()
        let secondPage = try await engine.lookup(
            symbol: "Marker",
            freshness: freshness,
            options: WhereOptions(includeReferences: true, offset: WhereRenderer.listCap)
        )

        let served = Self.listedFiles(in: firstPage) + Self.listedFiles(in: secondPage)

        #expect(Set(served).count == served.count)
        #expect(Set(served).count == total)
    }

    /// Both counts are separate facts about the same store, and a header naming only the louder one claims less than its own body.
    @Test
    func theHeaderNamesBothStalenessCountsWhenBothApply() {
        #expect(SemanticAxis.stale(newerFiles: 2, deletedOccurrenceFiles: 3).rendered
            == "stale (2 files changed since last build, 3 occurrence files deleted since last build)")
        #expect(SemanticAxis.stale(newerFiles: 1, deletedOccurrenceFiles: 0).rendered
            == "stale (1 file changed since last build)")
        #expect(SemanticAxis.stale(newerFiles: 0, deletedOccurrenceFiles: 1).rendered
            == "stale (1 occurrence file deleted since last build)")
    }

    /// The over-claim this axis knowingly carries, pinned so it is a specified behaviour rather than a surprise.
    ///
    /// "Changed since last build" is decided on the file's change moment (the later of its mtime and ctime), because no hash taken *at build time* exists to compare against — the index store records no per-file content hash. A file rewritten with the bytes that were built therefore labels, and the label is still the true statement it makes: the file has been written since the build, so the line the store names may have moved. It over-warns and never under-warns, which is the direction to err, and it matches the declaring-file refusal exactly rather than inventing a second meaning for the same column.
    @Test
    func aByteIdenticalRewriteStillLabels() async throws {
        let root = try Self.makeRepoWithDeletableCaller()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        let original = try String(contentsOf: root.appendingPathComponent("Sources/Lib/Extra.swift"), encoding: .utf8)
        try TestSources.write("// briefly different\n" + original, to: "Sources/Lib/Extra.swift", in: root)
        _ = try await engine.ensureFresh()
        try TestSources.write(original, to: "Sources/Lib/Extra.swift", in: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(output.contains("(file changed since last build)"))
    }
}
