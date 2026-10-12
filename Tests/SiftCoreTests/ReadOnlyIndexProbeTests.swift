//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The read-only store probe finds the stores an engine finds, nested packages included.
@Suite(.temporaryDirectories)
struct ReadOnlyIndexProbeTests {
    @Test
    func aStoreBuiltIntoANestedPackagesOwnBuildDirectoryIsFound() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\nimport PackageDescription\n", to: "Pkg/Package.swift", in: root)
        try TestSources.write("func helper() {}\n", to: "Pkg/Sources/Lib/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let units = root.appendingPathComponent("Pkg/.build/DerivedData/Index.noindex/DataStore/v5/units")
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data().write(to: units.appendingPathComponent("u1"))
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("index store: Pkg/.build/DerivedData — "))
        #expect(ReadOnlyIndex.hasIndexStore(atRoot: root.path))
    }
}
