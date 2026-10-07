//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the other-owner mark on a class's row by written name whose clause writes the class's name only behind the owner of another class of the name.
@Suite(.temporaryDirectories, .serialized)
struct WhereOtherOwnerMarkTests {
    /// The row of the subclass whose clause writes the nested class's qualified name.
    private static var markedRow: String {
        "Lib.W — class — Sources/Lib/Base.swift:13  (clause writes NS.Base)"
    }

    /// With the store, the top-level class's block by written name marks the subclass of the nested class, and keeps it.
    @Test
    func theStoreAnswerMarksAClauseBehindAnotherOwner() async throws {
        let output = try await WhereAliasSeedStoreTests.answer("Lib.Base", store: true, suite: Self.self)

        #expect(WhereAliasSeedStoreTests.rows(of: "Base", in: output).contains(Self.markedRow), "\(output)")
    }

    /// Without the store, the same row carries the same mark.
    @Test
    func withoutTheStoreAClauseBehindAnotherOwnerIsMarked() async throws {
        let output = try await WhereAliasSeedStoreTests.answer("Lib.Base", store: false, suite: Self.self)

        #expect(WhereAliasSeedStoreTests.rows(of: "Base", in: output).contains(Self.markedRow), "\(output)")
    }

    /// The nested class's own block leaves a clause written behind its own owner unmarked.
    @Test
    func aClauseBehindTheAskedOwnerIsNotMarked() async throws {
        let output = try await WhereAliasSeedStoreTests.answer("NS.Base", store: false, suite: Self.self)

        #expect(WhereAliasSeedStoreTests.rows(of: "Base", in: output).contains("Lib.W — class — Sources/Lib/Base.swift:13"), "\(output)")
    }
}
