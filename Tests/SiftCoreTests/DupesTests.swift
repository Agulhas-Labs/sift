//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// What `sift dupes` promises: groups of bodies alike by the rare calls they share, joined across pairs, and a one-line answer where nothing is.
@Suite(.temporaryDirectories)
struct DupesTests {
    /// Three writers of the temp-file-and-rename shape across two types, named nothing alike.
    private static let writers: [String: String] = [
        "Sources/Depot/DepotStore.swift": """
        struct DepotStore {
            func save(_ data: Data, to url: URL) throws {
                let temporary = url.appendingPathComponent(".tmp")
                try data.write(to: temporary)
                guard rename(temporary.path, url.path) == 0 else {
                    throw failure(String(cString: strerror(errno)))
                }
            }

            func stash(_ text: String, to url: URL) throws {
                let scratch = url.appendingPathComponent(".tmp")
                try Data(text.utf8).write(to: scratch)
                guard rename(scratch.path, url.path) == 0 else {
                    throw failure(String(cString: strerror(errno)))
                }
            }
        }
        """,
        "Sources/Catalogue/CatalogueStore.swift": """
        struct CatalogueStore {
            func flush(_ text: String, into url: URL) throws {
                let scratch = url.appendingPathComponent(".tmp")
                try Data(text.utf8).write(to: scratch)
                guard rename(scratch.path, url.path) == 0 else {
                    throw failure(String(cString: strerror(errno)))
                }
            }
        }
        """,
    ]

    /// Bodies built out of the calls every Swift file makes — alike in every call they make, and none of those calls rare.
    private static let commonplace: [String: String] = [
        "Sources/Shelf/ShelfIndex.swift": """
        struct ShelfIndex {
            func labels() -> [String] { rows.map(\\.name).sorted().reversed() }
            func widths() -> [Int] { rows.map(\\.width).sorted().reversed() }
            func names() -> [String] { rows.map(\\.name).sorted().reversed() }
            func spans() -> [Int] { rows.map(\\.span).sorted().reversed() }
        }
        """,
        "Sources/Depot/DepotCatalog.swift": """
        struct DepotCatalog {
            func tally() -> [Int] { entries.map(\\.count).sorted().reversed() }
            func weights() -> [Int] { entries.map(\\.weight).sorted().reversed() }
            func labels() -> [String] { entries.map(\\.label).sorted().reversed() }
        }
        """,
    ]

    private static var tree: [String: String] {
        writers.merging(commonplace) { first, _ in first }
    }

    private static func answer(over sources: [String: String]) -> DupesAnswer {
        let fingerprints = sources
            .sorted { $0.key < $1.key }
            .flatMap { FingerprintScanner.fingerprints(in: $0.value, path: $0.key) }
        return DupesSearch.answer(scope: [], fingerprints: fingerprints, filesScanned: sources.count)
    }

    /// A fingerprint built by hand, for the properties that are about pairs rather than about parsing.
    private static func fingerprint(line: Int, endLine: Int, path: String = "Sources/Depot/DepotStore.swift", callees: Set<String>) -> DeclarationFingerprint {
        DeclarationFingerprint(
            declaration: StructuralMatch(path: path, line: line, endLine: endLine, kind: "func", qualifiedName: "DepotStore.save", signature: "func save()"),
            callees: callees,
            skeleton: [],
            typeNames: []
        )
    }

    /// The finding the audit exists for: three writers across two types are one group, and bodies alike only in common calls are none.
    @Test
    func nearDuplicateWritersAcrossTypesAreOneGroupOfThree() {
        let found = Self.answer(over: Self.tree)
        let names = found.groups.first?.members.map(\.declaration.qualifiedName)

        #expect(found.totalGroups == 1)
        #expect(names == ["CatalogueStore.flush(_:into:)", "DepotStore.save(_:to:)", "DepotStore.stash(_:to:)"])
        #expect(found.groups.first?.sharedByEveryMember == true)
        #expect(found.groups.first?.sharedCallees.contains("rename") == true)

        let rendered = DupesRenderer.render(answer: found)
        #expect(rendered.contains("1 group(s) of near-duplicate bodies at 0.50"))
        #expect(rendered.contains("3 declarations"))
        #expect(!rendered.contains("ShelfIndex"))
    }

    /// A path argument restricts the scan to the files under it, and the census counts only those.
    @Test
    func aPathRestrictsTheScan() async throws {
        let root = try TemporaryDirectory.make("dupes")
        for (path, source) in Self.tree {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: url)
        }
        let listed = Self.tree.keys.sorted()
        let search = DupesSearch(repoRoot: root, enumerator: FileEnumerator(repoRoot: root, config: SiftConfig()) { listed })

        let narrowed = await search.run(scope: ["./Sources/Depot/"])
        let whole = await search.run(scope: [])

        #expect(narrowed.census.filesScanned == 2)
        #expect(narrowed.groups.first?.members.map(\.declaration.qualifiedName) == ["DepotStore.save(_:to:)", "DepotStore.stash(_:to:)"])
        #expect(whole.census.filesScanned == 4)
        #expect(whole.groups.first?.members.count == 3)
    }

    /// A tree where no pair clears the floor answers in one line that names the floor, and the numbers it was read against.
    @Test
    func nothingAboveTheFloorIsSaidInOneLine() {
        let rendered = DupesRenderer.render(answer: Self.answer(over: Self.commonplace))

        #expect(rendered.contains("no pair of declarations reached 0.50 shared-callee overlap"))
        #expect(rendered.contains("0 declaration(s) with 3 or more calls compared, of 7 with a body in 2 file(s); 7 under 4 lines left out"))
        #expect(!rendered.contains("group(s) of near-duplicate bodies"))
    }

    /// A callee named by more declarations than the fan-out bound proposes no pair on its own, and one at the bound proposes every pair.
    @Test
    func aCalleeAboveTheFanOutBoundProposesNoPair() {
        let bound = SimilarityScore.dupesFanOutBound
        let crowded = (0 ... bound).map { Self.fingerprint(line: $0 * 10, endLine: $0 * 10 + 5, callees: ["rename", "\($0)"]) }

        #expect(DupesSearch.candidatePairs(among: crowded).isEmpty)
        #expect(DupesSearch.candidatePairs(among: Array(crowded.prefix(bound))).count == bound * (bound - 1) / 2)
    }

    /// When the fan-out bound excludes every callee of some compared declarations, the answer names how many, so a thin or empty result reads as the bound, not the tree.
    @Test
    func theFanOutBoundExcludingEveryCalleeIsNoted() {
        let bound = SimilarityScore.dupesFanOutBound
        let crowded = (0 ..< bound + 5).map { Self.fingerprint(line: $0 * 10, endLine: $0 * 10 + 5, callees: ["print", "map", "filter"]) }
        let found = DupesSearch.answer(scope: [], fingerprints: crowded, filesScanned: 1)

        #expect(found.census.fanOutExcluded == bound + 5)

        let rendered = DupesRenderer.render(answer: found)
        #expect(rendered.contains("\(bound + 5) of the compared declarations named no callee within the fan-out bound"))
    }

    /// An ordinary duplicate pair, comfortably under the fan-out bound, carries no fan-out note.
    @Test
    func anOrdinaryDuplicatePairCarriesNoFanOutNote() {
        let found = Self.answer(over: Self.tree)

        #expect(found.census.fanOutExcluded == 0)
        #expect(!DupesRenderer.render(answer: found).contains("named no callee within the fan-out bound"))
    }

    /// A declaration nested inside another is never its duplicate, since the enclosing body's calls already include the nested one's.
    @Test
    func aNestedDeclarationIsNotPairedWithItsEncloser() {
        let shared: Set = ["rename", "strerror", "getpid", "fsync", "open", "close"]
        let filler = (0 ..< 3).map { Self.fingerprint(line: 100 + $0 * 10, endLine: 105 + $0 * 10, path: "Sources/Shelf/ShelfIndex.swift", callees: ["map", "\($0)"]) }
        let nested = [Self.fingerprint(line: 1, endLine: 20, callees: shared), Self.fingerprint(line: 5, endLine: 10, callees: shared)]
        let apart = [Self.fingerprint(line: 1, endLine: 4, callees: shared), Self.fingerprint(line: 5, endLine: 10, callees: shared)]

        #expect(DupesSearch.answer(scope: [], fingerprints: nested + filler, filesScanned: 2).totalGroups == 0)
        #expect(DupesSearch.answer(scope: [], fingerprints: apart + filler, filesScanned: 2).totalGroups == 1)
    }
}
