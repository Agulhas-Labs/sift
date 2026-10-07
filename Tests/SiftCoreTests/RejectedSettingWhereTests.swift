//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A rejected `indexStorePath` named on `where`'s own mode line, not only on `status`'s.
///
/// Split out of `SemanticWhereTests` to stay under its type-body-length budget.
@Suite(.temporaryDirectories)
struct RejectedSettingWhereTests {
    /// A rejected `indexStorePath` did not act whether or not some other probe went on to find a store — `status` already said so; `where`'s own mode line must say it too, rather than reading as though the setting was never seen at all.
    @Test
    func aRejectedConfigSettingIsNamedEvenWhenAnotherProbeFindsAStore() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        try TestSources.write(#"{ "indexStorePath": "not-a-store" }"#, to: ".sift.json", in: root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await SemanticStoreWarmUp.settled { try await engine.lookup(symbol: "helper()", freshness: freshness) }

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("passed over: indexStorePath 'not-a-store' in .sift.json is not an index store (no v<N>/units under it)"))
        #expect(output.contains("callers of Lib.helper() (1):"))
    }
}
