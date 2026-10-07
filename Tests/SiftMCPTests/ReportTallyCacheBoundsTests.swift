//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// What the tally cache keeps between reports: counts under a hashed name rather than a path, no entry past its retention, and one scan per window a transcript was read under.
@Suite(.temporaryDirectories) struct ReportTallyCacheBoundsTests {
    private typealias Cases = ReportTallyCacheTests

    /// A cache written before transcripts were named by hash holds nothing for this build: its entries are misses, never an error, and the file is rewritten without a path in it.
    @Test
    func anOldFormatCacheIsAMissAndIsRewrittenWithoutPaths() throws {
        let fixture = try Cases.fixture()
        let transcript = try Cases.write([Cases.digest("a", at: "2026-08-12T12:00:00Z")], to: fixture.project.appendingPathComponent("one.jsonl"), modified: Cases.written)
        let size = try Data(contentsOf: transcript).count
        let path = transcript.path
        let other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        // As the first format stored it: keyed by the path, at the transcript's own size and date, with no tally (a context that made no lookup).
        let entry: [String: Any] = ["size": size, "modified": Cases.written.timeIntervalSince1970]
        let old: [String: Any] = [
            "header": ["format": 1, "build": "test-build", "timeZone": Cases.utc.identifier],
            "transcripts": [path: entry, other: entry],
        ]
        try JSONSerialization.data(withJSONObject: old).write(to: fixture.cache.fileURL)

        let report = Cases.report(fixture)

        #expect(report.share?.tally.total == 1)
        #expect(report == Cases.report(fixture, cached: false))
        let written = try String(contentsOf: fixture.cache.fileURL, encoding: .utf8)
        #expect(!written.contains("one.jsonl"))
        #expect(!written.contains(fixture.project.lastPathComponent))
        #expect(try Cases.storedKeys(fixture).isSubset(of: Cases.keys(of: transcript)))
    }

    /// An entry whose transcript was last written before the retention and the window is dropped, though the transcript is still on disk.
    @Test
    func anEntryPastTheRetentionIsDropped() throws {
        let fixture = try Cases.fixture()
        let longAgo = try #require(ISO8601DateFormatter().date(from: "2026-05-08T12:00:00Z"))
        try Cases.write([Cases.digest("a", at: "2026-05-07T12:00:00Z")], to: fixture.project.appendingPathComponent("old.jsonl"), modified: longAgo)

        let wide = Cases.report(fixture, since: "2026-04-01")
        #expect(wide.share?.tally.total == 1)
        #expect(try Cases.storedKeys(fixture).count == 1)

        _ = Cases.report(fixture, since: "7d")

        #expect(try Cases.storedKeys(fixture).isEmpty)
    }

    /// An entry inside the retention outlives a narrower window that does not list its transcript, and the wider window reads it from the cache again.
    @Test
    func anEntryInsideTheRetentionOutlivesANarrowerWindow() throws {
        let fixture = try Cases.fixture()
        let earlier = try #require(ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z"))
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Cases.write([Cases.digest("a", at: "2026-08-01T10:00:00Z")], to: transcript, modified: earlier)
        let month = Cases.report(fixture, since: "30d")
        _ = Cases.report(fixture, since: "7d")

        // Rewritten behind the cache's back at the same size and date: only a stored scan still reports the first day.
        try Cases.write([Cases.digest("b", at: "2026-08-02T10:00:00Z")], to: transcript, modified: earlier)

        #expect(Cases.report(fixture, since: "30d") == month)
    }

    /// A transcript straddling both windows' starts keeps a scan for each: alternating `7d` and `30d` reads it from the cache rather than overwriting one window's scan with the other's.
    @Test
    func aTranscriptStraddlingTwoWindowsKeepsBothScans() throws {
        let fixture = try Cases.fixture()
        let transcript = fixture.project.appendingPathComponent("one.jsonl")
        try Cases.write([Cases.read("a", at: "2026-07-10T12:00:00Z", file: "DepotCatalog"), Cases.digest("b", at: "2026-08-14T12:00:00Z")], to: transcript, modified: Cases.written)
        let week = Cases.report(fixture, since: "7d")
        _ = Cases.report(fixture, since: "30d")

        // The same bytes but for a day, so a re-read would date the lookup to the 13th.
        try Cases.write([Cases.read("a", at: "2026-07-10T12:00:00Z", file: "DepotCatalog"), Cases.digest("b", at: "2026-08-13T12:00:00Z")], to: transcript, modified: Cases.written)

        #expect(Cases.report(fixture, since: "7d").share?.byDay.map(\.day) == ["2026-08-14"])
        #expect(Cases.report(fixture, since: "7d") == week)
    }

    /// Alternating windows over transcripts inside both, straddling either start and outside the narrower one, every cached report is the uncached one.
    @Test
    func alternatingWindowsReportWhatAnUncachedRunDoes() throws {
        let fixture = try Cases.fixture()
        try Cases.write([Cases.digest("a", at: "2026-08-12T12:00:00Z"), Cases.read("b", at: "2026-08-13T12:00:00Z")], to: fixture.project.appendingPathComponent("inside.jsonl"), modified: Cases.written)
        try Cases.write([Cases.read("c", at: "2026-07-10T12:00:00Z", file: "DepotCatalog"), Cases.digest("d", at: "2026-08-14T12:00:00Z")], to: fixture.project.appendingPathComponent("both.jsonl"), modified: Cases.written)
        try Cases.write([Cases.read("e", at: "2026-08-01T12:00:00Z"), Cases.read("f", at: "2026-08-12T12:00:00Z", file: "DepotCatalog")], to: fixture.project.appendingPathComponent("week.jsonl"), modified: Cases.written)
        let earlier = try #require(ISO8601DateFormatter().date(from: "2026-08-02T12:00:00Z"))
        try Cases.write([Cases.digest("g", at: "2026-08-02T10:00:00Z")], to: fixture.project.appendingPathComponent("month.jsonl"), modified: earlier)

        for since in ["7d", "30d", "7d", "30d", "14d", "7d", "30d"] {
            let cached = Cases.report(fixture, since: since)
            let uncached = Cases.report(fixture, since: since, cached: false)

            #expect(cached == uncached, "\(since)")
            #expect(cached.share?.tally.total == uncached.share?.tally.total, "\(since)")
        }

        #expect(Cases.report(fixture, since: "30d").share?.tally.total == 6)
    }
}
