//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers a plain `sift run -- swift test` in a checkout with no sift index yet: the run builds the index and prints the inventory line.
@Suite(.temporaryDirectories)
struct RunInventoryColdIndexTests {
    /// The run leaves an index in the checkout it ran in.
    @Test
    func aRunInACheckoutWithNoIndexLeavesAnIndexBehind() async throws {
        let repository = try RunInventoryNoteTests.package()
        let database = SiftPaths.cache(in: repository).appendingPathComponent(SiftPaths.indexFileName)
        #expect(!FileManager.default.fileExists(atPath: database.path))

        _ = try await RunInventoryNoteTests.run(in: repository, printing: RunInventoryNoteTests.ended(["testOne", "testTwo", "testThree"]), exiting: 0)

        #expect(FileManager.default.fileExists(atPath: database.path))
    }

    /// A green run of every declared test reconciles, rather than saying the check was skipped.
    @Test
    func aGreenRunInACheckoutWithNoIndexReportsAllDeclaredTests() async throws {
        let repository = try RunInventoryNoteTests.package()
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: RunInventoryNoteTests.ended(["testOne", "testTwo", "testThree"]), exiting: 0)

        #expect(thrown == nil)
        #expect(recorded.printed.contains("inventory: 3 declared, 3 reported"))
    }
}
