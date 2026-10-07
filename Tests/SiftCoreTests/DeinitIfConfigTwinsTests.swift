//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Two deinits of one type in the branches of an `#if` are each labelled with the condition that tells them apart, and a list of deinits past its cap says how many it left out.
@Suite(.serialized, .temporaryDirectories)
struct DeinitIfConfigTwinsTests {
    static var source: String {
        """
        final class Twice {
            #if os(macOS)
            deinit {}
            #else
            deinit {}
            #endif
        }
        """
    }

    /// `where` lists each twin with its condition, and `digest Twice.deinit` offers each by its file range under the same label, since the two share one qualified target.
    @Test
    func twinDeinitsAreLabelledWithTheirConditions() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/App/Twice.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "Twice.deinit", freshness: engine.ensureFresh())
        let digested = try engine.digest(target: "Twice.deinit", options: DigestOptions())

        #expect(located.contains("Twice.deinit — deinit — Sources/App/Twice.swift:3  [#if os(macOS)]"), "\(located)")
        #expect(located.contains("Twice.deinit — deinit — Sources/App/Twice.swift:5  [#else of #if os(macOS)]"), "\(located)")
        #expect(digested.contains("digest Sources/App/Twice.swift:3 — deinit — Sources/App/Twice.swift:3  [#if os(macOS)]"), "\(digested)")
        #expect(digested.contains("digest Sources/App/Twice.swift:5 — deinit — Sources/App/Twice.swift:5  [#else of #if os(macOS)]"), "\(digested)")
        for line in [3, 5] {
            let followed = try engine.digest(target: "Sources/App/Twice.swift:\(line)", options: DigestOptions())
            #expect(!followed.contains("is ambiguous"), "\(followed)")
            #expect(followed.contains("deinit {}"), "\(followed)")
        }
    }

    /// The deinits past the cap are counted on a `truncated:` line, as every other list of declarations does.
    @Test
    func deinitsPastTheCapAreCounted() {
        let found = (1 ... 3).map { DeinitLookup.Found(qualifiedName: "Twice.deinit", path: "Sources/App/Twice.swift", line: $0, endLine: $0) }
        let lines = DeinitLookup.whereLines(for: DeinitLookup.Lookup(cited: [], found: found), cap: 1)

        #expect(lines == ["declarations (3):", "  Twice.deinit — deinit — Sources/App/Twice.swift:1", "  truncated: 2 more declarations"])
    }
}
