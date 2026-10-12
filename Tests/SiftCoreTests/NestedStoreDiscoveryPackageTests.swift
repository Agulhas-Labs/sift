//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An `xcodebuild -derivedDataPath` store inside a nested package's own `.build` is that package's, so discovery names the package on it, and it answers only for that package's files.
@Suite(.temporaryDirectories)
struct NestedStoreDiscoveryPackageTests {
    /// A store shape — a versioned `units` directory holding one unit — which is all discovery reads.
    private static func makeStore(at url: URL) throws {
        let units = url.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data().write(to: units.appendingPathComponent("u1"))
    }

    private static func discovery(in root: URL) -> IndexStoreDiscovery {
        var discovery = IndexStoreDiscovery(repoRoot: root, config: SiftConfig(), derivedDataRoot: root.appendingPathComponent("no-dd"))
        discovery.packageDirectories = ["", "Tools/Lint"]
        return discovery
    }

    @Test
    func theInPackageDerivedDataProbeNamesTheNestedPackageOnItsStore() throws {
        let root = try TestSources.makeTempRepo()
        try Self.makeStore(at: root.appendingPathComponent("Tools/Lint/.build/DerivedData/Index.noindex/DataStore"))

        let found = try #require(Self.discovery(in: root).discover())

        #expect(found.provenance == .inTree("Tools/Lint/.build/DerivedData"))
        #expect(found.package == "Tools/Lint")
        #expect(!DiscoveredStore.answers(package: found.package, forFile: "Sources/Lint/Shared.swift"))
    }

    @Test
    func theInTreeWalkNamesTheNestedPackageOnAStoreUnderItsBuildAndNoneOnAStoreUnderTheRoots() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try Self.makeStore(at: root.appendingPathComponent("Tools/Lint/.build/DerivedData/Index.noindex/DataStore"))
        try Self.makeStore(at: root.appendingPathComponent(".build/runner-dd/Index.noindex/DataStore"))

        let found = Self.discovery(in: root).discoverInTree(excluding: nil)

        #expect(found.map(\.provenance) == [.inTree(".build/runner-dd"), .inTree("Tools/Lint/.build/DerivedData")])
        #expect(found.map(\.package) == ["", "Tools/Lint"])
    }

    /// A store an xcodebuild run inside the package put straight into its build directory is that package's too.
    @Test
    func aStoreDirectlyInANestedPackagesBuildDirectoryIsThatPackages() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try Self.makeStore(at: root.appendingPathComponent("Tools/Lint/.build/Index.noindex/DataStore"))

        let found = Self.discovery(in: root).discoverInTree(excluding: nil)

        #expect(found.map(\.provenance) == [.inTree("Tools/Lint/.build")])
        #expect(found.map(\.package) == ["Tools/Lint"])
    }
}
