//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An `xcodebuild -derivedDataPath <Pkg>/.build/DerivedData` build into a SwiftPM package's own `.build` is found by discovery, where it once took an `indexStorePath`, and the no-store hint names the places searched rather than implying an ignored directory is.
@Suite(.temporaryDirectories)
struct InPackageDerivedDataStoreTests {
    /// An empty store shape — a versioned `units` directory holding one file — which is all discovery reads.
    private static func makeStoreShape(at url: URL) throws {
        let units = url.appendingPathComponent("v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data().write(to: units.appendingPathComponent("u1"))
    }

    /// Discovery with no Xcode DerivedData to scan, so only the tree's own stores can answer.
    private static func discovery(in root: URL, config: SiftConfig = SiftConfig()) -> IndexStoreDiscovery {
        IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd"))
    }

    @Test
    func statusFindsAStoreBuiltIntoANestedPackagesOwnBuildDirectory() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\n", to: "Pkg/Package.swift", in: root)
        try TestSources.write("func helper() {}\n", to: "Pkg/Sources/Lib/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try Self.makeStoreShape(at: root.appendingPathComponent("Pkg/.build/DerivedData/Index.noindex/DataStore"))
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("index store: Pkg/.build/DerivedData — "))
        #expect(status.contains("Pkg/.build/DerivedData/Index.noindex/DataStore"))
        #expect(!status.contains("index store: none found"))
    }

    @Test
    func aDerivedDataPathUnderADirectoryThatHoldsNoPackageIsNotSearched() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}\n", to: "Other/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try Self.makeStoreShape(at: root.appendingPathComponent("Other/.build/DerivedData/Index.noindex/DataStore"))
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("index store: none found"))
    }

    @Test
    func theRootsOwnBuildDirectoryIsSearchedWithNoManifestThere() throws {
        let root = try TestSources.makeTempRepo()
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/DerivedData/Index.noindex/DataStore"))

        let found = try #require(Self.discovery(in: root).discover())

        #expect(found.provenance == .inTree(".build/DerivedData"))
        #expect(found.path.path.hasSuffix("/.build/DerivedData/Index.noindex/DataStore"))
    }

    @Test
    func everyEarlierProbeStillWinsOverAnInPackageDerivedDataStore() throws {
        let root = try TestSources.makeTempRepo()
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/DerivedData/Index.noindex/DataStore"))
        try Self.makeStoreShape(at: root.appendingPathComponent(".build/out"))
        try Self.makeStoreShape(at: root.appendingPathComponent("Custom/DataStore"))

        var config = SiftConfig()
        config.indexStorePath = "Custom/DataStore"

        let unconfigured = Self.discovery(in: root).discover()
        let configured = Self.discovery(in: root, config: config).discover()

        #expect(unconfigured?.provenance == .swiftPMBuild)
        #expect(configured?.provenance == .config)
    }

    @Test
    func theHintNamesWhereDiscoverySearchesAndTheConfigLineForAnywhereElse() {
        let note = SiftEngine.nestedStoreNote

        #expect(!note.contains("ignored directories"))
        #expect(note.contains("-derivedDataPath <Pkg>/.build/DerivedData where <Pkg> is the repo root or a directory holding a Package.swift"))
        #expect(note.contains("any other custom -derivedDataPath needs indexStorePath set in .sift.json"))
        #expect(note.contains("{\"indexStorePath\": \"<path>/Index.noindex/DataStore\"}"))
    }
}
