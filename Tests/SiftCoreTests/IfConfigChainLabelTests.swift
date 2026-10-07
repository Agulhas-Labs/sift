//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An `#elseif` and an `#else` after one are labelled with every clause before them in the chain, so a reader can tell which branch each declaration is in.
@Suite(.temporaryDirectories)
struct IfConfigChainLabelTests {
    static var source: String {
        """
        #if os(macOS)
        public func flavor() -> String { "mac" }
        #elseif canImport(UIKit)
        public func flavor() -> String { "ui" }
        #else
        public func flavor() -> String { "other" }
        #endif
        """
    }

    @Test
    func anElseifAndTheElseAfterItNameTheWholeChain() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.source, to: "Sources/Lib/Pick.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "flavor", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(located.contains("Sources/Lib/Pick.swift:2  [#if os(macOS)]"), "\(located)")
        #expect(located.contains("Sources/Lib/Pick.swift:4  [#elseif canImport(UIKit) of #if os(macOS)]"), "\(located)")
        #expect(located.contains("Sources/Lib/Pick.swift:6  [#else of #if os(macOS), #elseif canImport(UIKit)]"), "\(located)")
    }
}
