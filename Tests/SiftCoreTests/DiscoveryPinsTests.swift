//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The in-package DerivedData probe passes over a package inside a nested checkout, and the newest unit wins between packages.
@Suite(.temporaryDirectories)
struct DiscoveryPinsTests {
    /// A store shape — a versioned `units` directory holding one unit written at `date` — which is all discovery reads.
    private static func makeStore(at url: URL, builtAt date: Date = Date()) throws {
        let unit = url.appendingPathComponent("v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: unit)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
    }

    private static func discovery(in root: URL, packages: [String]) -> IndexStoreDiscovery {
        var discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        discovery.packageDirectories = packages
        return discovery
    }

    private static var derivedDataStore: String {
        ".build/DerivedData/Index.noindex/DataStore"
    }

    @Test
    func anInPackageDerivedDataStoreInsideANestedCheckoutIsNotUsedForTheRoot() throws {
        let root = try TemporaryDirectory.make("discovery-pins")
        let inner = root.appendingPathComponent("Inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere/.git/worktrees/inner".utf8).write(to: inner.appendingPathComponent(".git"))
        try Self.makeStore(at: inner.appendingPathComponent("Kit").appendingPathComponent(Self.derivedDataStore))

        let discovered = Self.discovery(in: root, packages: ["Inner/Kit"]).discover()

        #expect(discovered == nil)
    }

    @Test
    func theNewestInPackageDerivedDataStoreWinsBetweenPackages() throws {
        let root = try TemporaryDirectory.make("discovery-pins")
        try Self.makeStore(at: root.appendingPathComponent("A").appendingPathComponent(Self.derivedDataStore), builtAt: Date(timeIntervalSinceNow: -3600))
        try Self.makeStore(at: root.appendingPathComponent("B").appendingPathComponent(Self.derivedDataStore), builtAt: Date())
        try Self.makeStore(at: root.appendingPathComponent("C").appendingPathComponent(Self.derivedDataStore), builtAt: Date(timeIntervalSinceNow: -7200))

        let discovered = try #require(Self.discovery(in: root, packages: ["C", "B", "A"]).discover())

        #expect(discovered.package == "B")
        #expect(discovered.provenance == .inTree("B/.build/DerivedData"))
    }
}
