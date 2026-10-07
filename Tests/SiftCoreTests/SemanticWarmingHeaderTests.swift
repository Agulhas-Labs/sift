//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the header's semantic verdict when the index store is present but not answering — still warming, or failed to open.
@Suite(.temporaryDirectories)
struct SemanticWarmingHeaderTests {
    /// The header says warming too, on both tools that print the axis — never `none (no index store — see note)`.
    ///
    /// Warming that reaches the renderers as the same input as a missing store has the header tell the reader to build while the body beneath it says no build would help: one answer contradicting itself, with the wrong half on the line read first. A zero budget holds a real open in its warming state — one engine per query, since each engine's open goes on in the background and the next query on it may find it finished — and a repository never built is the control that must still say `none`.
    @Test
    func aWarmingStoreIsWarmingInTheHeaderAndAMissingOneIsStillNone() async throws {
        let built = try SemanticWhereTests.makeBuiltRepo()
        let whereEngine = try SiftEngine(directory: built)
        let affectedEngine = try SiftEngine(directory: built)
        whereEngine.openBudget = 0
        affectedEngine.openBudget = 0
        let unbuilt = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Sources/Lib/Caller.swift", in: unbuilt)
        try TestSources.commitAll(in: unbuilt, message: "never built")
        let unbuiltEngine = try SiftEngine(directory: unbuilt)

        let warmingWhere = try await whereEngine.lookup(symbol: "helper()", freshness: whereEngine.ensureFresh())
        let warmingAffected = try await affectedEngine.affected(options: AffectedOptions(), freshness: affectedEngine.ensureFresh())
        let missingWhere = try await unbuiltEngine.lookup(symbol: "helper()", freshness: unbuiltEngine.ensureFresh())
        let headers = [warmingWhere, warmingAffected, missingWhere].map { $0.split(separator: "\n").first.map(String.init) ?? "" }

        #expect(headers[0].hasSuffix("semantic: warming (index store still loading — ask again shortly)"), "\(warmingWhere)")
        #expect(headers[1].hasSuffix("semantic: warming (index store still loading — ask again shortly)"), "\(warmingAffected)")
        for answer in [warmingWhere, warmingAffected] {
            #expect(!answer.contains("no index store for this tree yet"), "\(answer)")
            #expect(answer.contains("still warming"), "the body and the header now agree: \(answer)")
        }
        #expect(headers[2].hasSuffix("semantic: none (no index store — see note)"), "\(missingWhere)")
    }

    /// A store that failed to open says so in the header, and never advises the build that cannot fix it.
    ///
    /// Reading `none (no index store — see note)` above a body saying the store was found and failed to open is the same contradiction as warming, one case over. Still `none`, because semantics really are unavailable; only the reason changes. The failure is a real one: a regular file where the store's database directory has to be created. Asked twice on `where`, because the second query takes the cached failure rather than a fresh open, and nothing else holds the two paths to the same answer.
    @Test
    func aStoreThatFailedToOpenSaysSoAndAMissingOneStillSaysBuild() async throws {
        let root = try Self.repository(named: "store that cannot open")
        // v5/units is what makes this look like a real store to discovery's tightened shape check;
        // the corrupted isdb cache below is what then makes opening it fail.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        try Data("not a directory".utf8).write(to: SiftPaths.cache(in: root).appendingPathComponent("isdb"))
        let missing = try SiftEngine(directory: Self.repository(named: "no store at all"))

        let answers = try await [
            engine.lookup(symbol: "helper()", freshness: freshness),
            engine.lookup(symbol: "helper()", freshness: freshness),
            engine.affected(options: AffectedOptions(), freshness: freshness),
        ]
        let missingWhere = try await missing.lookup(symbol: "helper()", freshness: missing.ensureFresh())
        let headers = (answers + [missingWhere]).map { $0.split(separator: "\n").first.map(String.init) ?? "" }

        #expect(headers.dropLast().allSatisfy { $0.hasSuffix("semantic: none (index store found but failed to open)") }, "\(headers)")
        for answer in answers {
            #expect(!answer.contains("no index store for this tree yet"), "\(answer)")
            #expect(answer.contains("but failed to open:"), "the body still quotes the error: \(answer)")
        }
        #expect(headers.last?.hasSuffix("semantic: none (no index store — see note)") == true, "\(missingWhere)")
    }

    /// A reference sweep's "references: UNAVAILABLE" line says why in the same terms as the header above it.
    ///
    /// One line served all three states and told each to grep or build: under a warming header that contradicts the answer and advises the grep the warming note forbids, and under a failed open it advises a build that cannot fix it. A store genuinely missing has no UNAVAILABLE line at all: its name-matched sites are the sweep, and its line says so.
    @Test
    func aReferenceSweepSaysWhyItHasNoReferencesInTheHeadersTerms() async throws {
        let warming = try SiftEngine(directory: SemanticWhereTests.makeBuiltRepo())
        warming.openBudget = 0
        let failedRoot = try Self.repository(named: "store that cannot open")
        try FileManager.default.createDirectory(at: failedRoot.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let failed = try SiftEngine(directory: failedRoot)
        let failedFreshness = try await failed.ensureFresh()
        try Data("not a directory".utf8).write(to: SiftPaths.cache(in: failedRoot).appendingPathComponent("isdb"))
        let missing = try SiftEngine(directory: Self.repository(named: "no store at all"))
        let sweep = WhereOptions(includeReferences: true)

        let answers = try await (
            warming: warming.lookup(symbol: "helper()", freshness: warming.ensureFresh(), options: sweep),
            failed: failed.lookup(symbol: "helper()", freshness: failedFreshness, options: sweep),
            missing: missing.lookup(symbol: "helper()", freshness: missing.ensureFresh(), options: sweep)
        )
        let references = [answers.warming, answers.failed, answers.missing].map { answer in
            answer.split(separator: "\n").first { $0.hasPrefix("references: UNAVAILABLE") }.map(String.init) ?? ""
        }

        #expect(references[0].contains("ask again shortly"), "\(answers.warming)")
        #expect(!references[0].contains("grep instead"), "\(answers.warming)")
        #expect(!references[0].contains("build the project"), "\(answers.warming)")
        #expect(references[1].contains("failed to open"), "\(answers.failed)")
        #expect(!references[1].contains("build"), "\(answers.failed)")
        // A store genuinely missing never advises dropping --syntactic — the caller never passed it — and, its
        // name-matched sites being the whole sweep there is, says so rather than sending the reader to grep.
        #expect(references[2] == "", "\(answers.missing)")
        #expect(answers.missing.contains("references: all sites by written name, paged by file"), "\(answers.missing)")
        #expect(!answers.missing.contains("drop --syntactic"), "\(answers.missing)")
    }

    /// Under `--syntactic` the store is never probed, so the sweep line cannot tell a caller to build: with a store already on disk, dropping the flag is the whole remedy.
    @Test
    func aSyntacticSweepNeverAdvisesABuildItCannotKnowIsNeeded() async throws {
        let root = try Self.repository(named: "built, asked syntactically")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let engine = try SiftEngine(directory: root)

        let answer = try await engine.lookup(
            symbol: "helper()",
            freshness: engine.ensureFresh(),
            options: WhereOptions(includeSemantic: false, includeReferences: true)
        )
        let line = answer.split(separator: "\n").first { $0.hasPrefix("references: UNAVAILABLE") }.map(String.init) ?? ""

        #expect(line.contains("drop --syntactic"), "\(answer)")
        #expect(!line.contains("build the project"), "\(answer)")
    }

    private static func repository(named message: String) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: message)
        return root
    }
}
