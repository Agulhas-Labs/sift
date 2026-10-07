//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// What a `where` answer says about the half of the question it did not answer, when the store is present but deliberately unused.
@Suite(.temporaryDirectories)
struct SyntacticWhereNoticeTests {
    /// `--syntactic` did not ask for callers/overrides at all, so there is nothing withheld to disclose — the `NOT ANSWERED` notice is dropped rather than shown, one line or long.
    @Test
    func aSyntacticQueryCarriesNoCallersOverridesNotice() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(
            symbol: "helper()",
            freshness: freshness,
            options: WhereOptions(includeSemantic: false)
        )

        #expect(output.contains("semantic disabled (--syntactic)"))
        #expect(!output.contains("NOT ANSWERED"))
    }

    /// A type's default section is headed "used by", never "callers/overrides" — its declarations have neither — so when the store is genuinely unavailable (asked for, not withheld by a flag) the stand-in notice, though now one line, still names the section it is standing in for.
    @Test
    func anUnavailableStoreOnATypeNamesUsedByNotCallersOverrides() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "unbuilt fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Base", freshness: freshness)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let noticeIndex = try #require(lines.firstIndex { $0.hasPrefix("used by: NOT ANSWERED") || $0.hasPrefix("callers/overrides: NOT ANSWERED") })

        #expect(lines[noticeIndex].hasPrefix("used by: NOT ANSWERED"))
        // The notice is exactly one of the answer's lines: the blank banner slot, then the result, follow directly.
        #expect(lines[noticeIndex + 1].isEmpty)
        #expect(lines[noticeIndex + 2].hasPrefix("declarations ("))
    }

    /// A store still warming has one, so the stand-in notice must not claim there is none — the mode line right above it already says the store was found and is still loading, and a notice contradicting it one line down reads as the answer disagreeing with itself.
    @Test
    func aWarmingStoreNoticeDoesNotContradictTheModeLine() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        engine.openBudget = 0
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modeIndex = try #require(lines.firstIndex { $0.hasPrefix("mode:") })
        let noticeIndex = try #require(lines.firstIndex { $0.hasPrefix("callers/overrides: NOT ANSWERED") })

        #expect(lines[modeIndex].contains("still warming"))
        #expect(!lines[noticeIndex].contains("no index store"))
        #expect(noticeIndex == modeIndex + 1)
    }

    /// A store that failed to open is a store that exists — the mode line says it was found and failed, so the stand-in notice below it must not claim there is none either.
    @Test
    func anOpenFailedStoreNoticeDoesNotContradictTheModeLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Sources/Lib/Caller.swift", in: root)
        try TestSources.commitAll(in: root, message: "store that cannot open")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build/index/store/v5/units"),
            withIntermediateDirectories: true
        )
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        try Data("not a directory".utf8).write(to: SiftPaths.cache(in: root).appendingPathComponent("isdb"))

        let output = try await engine.lookup(symbol: "helper()", freshness: freshness)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modeIndex = try #require(lines.firstIndex { $0.hasPrefix("mode:") })
        let noticeIndex = try #require(lines.firstIndex { $0.hasPrefix("callers/overrides: NOT ANSWERED") })

        #expect(lines[modeIndex].contains("failed to open"))
        #expect(!lines[noticeIndex].contains("no index store"))
        #expect(noticeIndex == modeIndex + 1)
    }
}
