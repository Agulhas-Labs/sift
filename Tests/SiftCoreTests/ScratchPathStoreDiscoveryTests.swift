//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A store built under a `--scratch-path` directory inside `.build` is found without `.sift.json` naming it.
@Suite(.temporaryDirectories)
struct ScratchPathStoreDiscoveryTests {
    private static func makeStore(at url: URL, builtAt date: Date) throws {
        let unit = url.appendingPathComponent("v5/units/u1")
        try FileManager.default.createDirectory(at: unit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: unit)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: unit.path)
    }

    private static func discover(in root: URL, config: SiftConfig = SiftConfig()) -> DiscoveredStore? {
        IndexStoreDiscovery(repoRoot: root, config: config, derivedDataRoot: root.appendingPathComponent("no-dd")).discover()
    }

    private static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    @Test
    func aNativeStoreUnderAScratchPathIsFound() throws {
        let root = try TemporaryDirectory.make("scratch-native")
        let store = root.appendingPathComponent(".build/work/arm64-apple-macosx/debug/index/store")
        try Self.makeStore(at: store, builtAt: Date())

        let found = try #require(Self.discover(in: root))

        #expect(Self.same(found.path, store), "\(found.path)")
    }

    @Test
    func aSwiftBuildStoreUnderAScratchPathIsFound() throws {
        let root = try TemporaryDirectory.make("scratch-out")
        let store = root.appendingPathComponent(".build/work/out")
        try Self.makeStore(at: store, builtAt: Date())

        let found = try #require(Self.discover(in: root))

        #expect(Self.same(found.path, store), "\(found.path)")
    }

    @Test
    func theNewestOfSeveralStoresWinsAcrossScratchPathsAndTheDefaults() throws {
        let root = try TemporaryDirectory.make("scratch-newest")
        let now = Date()
        let older = root.appendingPathComponent(".build/index/store")
        let middle = root.appendingPathComponent(".build/a/arm64-apple-macosx/debug/index/store")
        let newest = root.appendingPathComponent(".build/b/arm64-apple-macosx/release/index/store")
        try Self.makeStore(at: older, builtAt: now.addingTimeInterval(-300))
        try Self.makeStore(at: middle, builtAt: now.addingTimeInterval(-200))
        try Self.makeStore(at: newest, builtAt: now.addingTimeInterval(-100))

        let found = try #require(Self.discover(in: root))

        #expect(Self.same(found.path, newest), "\(found.path)")
    }

    @Test
    func aConfiguredPathStillOutranksAScratchPathStore() throws {
        let root = try TemporaryDirectory.make("scratch-config")
        let configured = root.appendingPathComponent("custom/store")
        try Self.makeStore(at: configured, builtAt: Date().addingTimeInterval(-500))
        try Self.makeStore(at: root.appendingPathComponent(".build/work/out"), builtAt: Date())
        var config = SiftConfig()
        config.indexStorePath = "custom/store"

        let found = try #require(Self.discover(in: root, config: config))

        #expect(Self.same(found.path, configured), "\(found.path)")
    }

    @Test
    func aNestedCheckoutsOwnBuildIsNotAScratchPath() throws {
        let root = try TemporaryDirectory.make("scratch-nested-checkout")
        let own = root.appendingPathComponent(".build/index/store")
        try Self.makeStore(at: own, builtAt: Date().addingTimeInterval(-500))
        let checkout = root.appendingPathComponent(".build/wt")
        let nestedBuild = checkout.appendingPathComponent(".build")
        try Self.makeStore(at: nestedBuild.appendingPathComponent("arm64-apple-macosx/debug/index/store"), builtAt: Date())
        try Data("gitdir: elsewhere".utf8).write(to: checkout.appendingPathComponent(".git"))
        try FileManager.default.createSymbolicLink(
            atPath: nestedBuild.appendingPathComponent("debug").path,
            withDestinationPath: "arm64-apple-macosx/debug"
        )

        let found = try #require(Self.discover(in: root))

        #expect(Self.same(found.path, own), "\(found.path)")
    }
}
