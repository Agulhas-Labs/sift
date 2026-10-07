//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The probe behind the occurrence axis: what it decides, and what it costs to decide it.
@Suite(.temporaryDirectories)
struct OccurrenceFreshnessTests {
    private static func makeProbe(root: URL, store: IndexStore, buildAnchor: Double) -> OccurrenceFreshness {
        OccurrenceFreshness(store: store, buildAnchor: buildAnchor) { absolute in
            let prefix = root.standardizedFileURL.path + "/"
            return absolute.hasPrefix(prefix) ? String(absolute.dropFirst(prefix.count)) : absolute
        }
    }

    /// The whole cost claim: one `stat` per distinct path, however many occurrences cite it.
    ///
    /// A symbol with forty references in one file is what makes this worth caching — the alternative is forty syscalls for one fact.
    @Test
    func aPathIsStattedOnceHoweverManyOccurrencesCiteIt() throws {
        let root = try TestSources.makeTempDirectory()
        let store = try TestSources.makeStore()
        let present = root.appendingPathComponent("Present.swift")
        try "let a = 1\n".write(to: present, atomically: true, encoding: .utf8)
        let probe = Self.makeProbe(root: root, store: store, buildAnchor: Date.distantFuture.timeIntervalSince1970)

        for _ in 0 ..< 40 {
            _ = probe.state(of: present.path)
        }
        _ = probe.state(of: root.appendingPathComponent("Gone.swift").path)

        #expect(probe.stats == 2)
    }

    @Test
    func aPathTheTreeNoLongerHasIsDeleted() throws {
        let root = try TestSources.makeTempDirectory()
        let store = try TestSources.makeStore()
        let probe = Self.makeProbe(root: root, store: store, buildAnchor: Date().timeIntervalSince1970)

        let state = probe.state(of: root.appendingPathComponent("Gone.swift").path)

        #expect(state == .deleted)
        #expect(probe.deletedFiles == ["Gone.swift"])
        #expect(state.marker == "  (file deleted since last build)")
    }

    /// A file the index has no row for is left alone rather than judged on an mtime nothing vouches for.
    ///
    /// Dependency sources and excluded trees arrive here routinely; calling them modified because their checkout postdates the build would put a caveat on every answer that cites one, which is how a caveat stops being read.
    @Test
    func aPresentFileTheIndexDoesNotKnowIsNeverCalledModified() throws {
        let root = try TestSources.makeTempDirectory()
        let store = try TestSources.makeStore()
        let outsider = root.appendingPathComponent("Outsider.swift")
        try "let a = 1\n".write(to: outsider, atomically: true, encoding: .utf8)
        let probe = Self.makeProbe(root: root, store: store, buildAnchor: 0)

        let state = probe.state(of: outsider.path)

        #expect(state == .live)
        #expect(probe.modifiedFiles.isEmpty)
        #expect(state.marker == nil)
    }
}
