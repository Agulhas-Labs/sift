//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the line a refused `--filter` carries when it names a type the index declares, through `RunCommand` itself: the wiring that hands the outcome to `UnmatchedFilterHint`, not the lookup alone.
@Suite(.temporaryDirectories)
struct RunUnmatchedSuitesHintTests {
    private static var source: String {
        """
        import XCTest

        struct Pallet {}

        final class PalletTests: XCTestCase {
            func testOne() {
                _ = Pallet()
            }
        }
        """
    }

    @Test
    func aRefusedFilterNamingADeclaredTypeCarriesTheSuitesThatReachIt() async throws {
        let repository = try await RunInventoryNoteTests.indexedPackage(source: Self.source)
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: ["warning: No matching test cases were run"], exiting: 0, extraArguments: ["--filter", "Pallet"])

        #expect(thrown?.rawValue == RunTestSelector.exitCode)
        #expect(recorded.printed.contains("  Pallet is declared in Tests/GizmoTests/PalletTests.swift; suites referencing it: GizmoTests.PalletTests — pass one as --filter"))
    }

    @Test
    func aRefusedFilterNamingNothingTheIndexDeclaresCarriesNoLine() async throws {
        let repository = try await RunInventoryNoteTests.indexedPackage(source: Self.source)
        let (recorded, thrown) = try await RunInventoryNoteTests.run(in: repository, printing: ["warning: No matching test cases were run"], exiting: 0, extraArguments: ["--filter", "NothingLikeThis"])

        #expect(thrown?.rawValue == RunTestSelector.exitCode)
        #expect(!recorded.printed.contains("is declared in"))
    }
}
