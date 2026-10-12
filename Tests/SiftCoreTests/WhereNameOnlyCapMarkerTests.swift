//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The shell's sample of a function's name-matched sites says how many it left out, for the places the name is written with no call as for the calls.
@Suite(.temporaryDirectories)
struct WhereNameOnlyCapMarkerTests {
    private static let writtenCount = 8
    private static let cap = 5

    @Test
    func theWrittenWithNoCallBlockCountsTheSitesItCutOff() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func relay() {}\n", to: "Sources/App/Relay.swift", in: root)
        for index in 1 ... Self.writtenCount {
            try TestSources.write("let handed\(index) = relay\n", to: "Sources/App/Handed\(index).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)

        let output = try await engine.lookup(symbol: "relay()", freshness: engine.ensureFresh(), options: WhereOptions(nameMatchedSiteCap: Self.cap))

        #expect(output.contains("but the name is written \(Self.writtenCount) times with no call"), "\(output)")
        #expect(output.contains("truncated: \(Self.writtenCount - Self.cap) more"), "\(output)")
    }
}
