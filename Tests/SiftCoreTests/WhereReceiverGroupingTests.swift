//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A qualified member name as common as `record`, asked with no store: the sites kept because their receiver is a type outside the tree are named by receiver in the count, and a Swift Testing `Issue` is proven another type.
@Suite(.temporaryDirectories)
struct WhereReceiverGroupingTests {
    private static var source: String {
        """
        import Testing
        import SwiftUI

        struct Depot {
            func record() {}
        }
        struct Orchard {
            func checks() {
                Issue.record("one")
                Issue.record("two")
                Binding<Int>.record(1)
                Binding<Int>.record(2)
                Depot().record()
            }
        }
        """
    }

    private static func answer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/App/Uses.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return try await CallSiteHeadingTests.lookup("Depot.record", in: root)
    }

    /// `Issue.record` is Swift Testing's own, so it is dropped, and the kept outside-tree receivers are named with their counts.
    @Test
    func theKeptReceiversAreNamedInTheCount() async throws {
        let output = try await Self.answer()
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("\"record\" (") })

        #expect(!output.contains("Issue.record"), "\(output)")
        #expect(line.contains("on types outside the tree (Binding ×2)"), "\(line)")
    }
}
