//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an invalidation gap: stored module attribution depends on inputs OUTSIDE the file it is keyed to — the manifest, the XcodeGen files, the `moduleMap`, and the resolver's own logic — and content-keyed invalidation can never see those change.
///
/// The failure it guards: an upgraded binary that fixes manifest parsing, while `status` keeps serving the old binary's guessed modules forever — `index` is a no-op (no source changed), and only a full `reset` heals the lot. Every test here asserts the heal happens on an ordinary query, with no reset and no reindex of source content.
@Suite(.temporaryDirectories)
struct ResolutionInvalidationTests {
    private static var toolFirstManifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "VendorTools",
            targets: [
                .executableTarget(name: "Linter", path: "Linter/Sources/Linter"),
            ]
        )
        """
    }

    private static func makeToolFirstRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(toolFirstManifest, to: "Package.swift", in: root)
        try TestSources.write("struct Warden {}\n", to: "Linter/Sources/Linter/Warden.swift", in: root)
        try TestSources.commitAll(in: root, message: "tool-first layout")
        return root
    }

    /// Nudges a file's mtime forward so an edit made microseconds after the last stat still reads as a change.
    private static func bumpMtime(of relativePath: String, in root: URL) throws {
        let path = root.appendingPathComponent(relativePath).path
        let current = try (FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(2)], ofItemAtPath: path)
    }

    /// The upgrade case: an index written by an older binary carries wrong modules and a stale (or missing) fingerprint — the first query of the new binary must re-attribute everything, no reset required.
    @Test
    func anIndexWrittenByAnOlderBinaryReattributesOnFirstQuery() async throws {
        let root = try Self.makeToolFirstRepo()
        let first = try SiftEngine(directory: root)
        _ = try await first.ensureFresh()

        _ = try first.store.reattributeModules { _ in ("VendorTools", true) }
        try first.store.setMetaValue("v0:written-by-an-older-binary", forKey: "resolution_fingerprint")
        #expect(try first.store.moduleNames() == ["VendorTools"])

        let upgraded = try SiftEngine(directory: root)
        _ = try await upgraded.ensureFresh()

        #expect(try upgraded.store.moduleNames() == ["Linter"])
        #expect(try upgraded.store.filesWithGuessedModule().isEmpty)
    }

    /// A manifest edited mid-session re-attributes the files it governs without any of them changing.
    @Test
    func anEditedManifestReattributesMidSession() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("// swift-tools-version: 6.0\n", to: "Package.swift", in: root)
        try TestSources.write("struct Alpha {}\n", to: "Sources/Lib/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "conventional layout")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        #expect(try engine.store.fileRow(path: "Sources/Lib/Alpha.swift")?.module == "Lib")

        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Renamed", path: "Sources/Lib")])
            """,
            to: "Package.swift",
            in: root
        )
        try Self.bumpMtime(of: "Package.swift", in: root)
        _ = try await engine.ensureFresh()

        #expect(try engine.store.fileRow(path: "Sources/Lib/Alpha.swift")?.module == "Renamed")
    }

    /// A `moduleMap` written mid-session updates rows already stored, not just files indexed afterwards.
    @Test
    func aModuleMapEditReattributesExistingRows() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Legacy/Widgets/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "unmapped layout")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        #expect(try engine.store.fileRow(path: "Legacy/Widgets/Alpha.swift")?.moduleGuessed == true)

        try TestSources.write(#"{"moduleMap": {"Legacy/Widgets": "Widgets"}}"#, to: ".sift.json", in: root)
        try Self.bumpMtime(of: ".sift.json", in: root)
        _ = try await engine.ensureFresh()

        let row = try engine.store.fileRow(path: "Legacy/Widgets/Alpha.swift")
        #expect(row?.module == "Widgets")
        #expect(row?.moduleGuessed == false)
    }

    /// A manifest appearing mid-session (a package being born) is adopted the same way.
    @Test
    func aManifestAppearingMidSessionIsAdopted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Custom/Place/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "no manifest yet")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        #expect(try engine.store.fileRow(path: "Custom/Place/Alpha.swift")?.moduleGuessed == true)

        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Placed", path: "Custom/Place")])
            """,
            to: "Package.swift",
            in: root
        )
        _ = try await engine.ensureFresh()

        #expect(try engine.store.fileRow(path: "Custom/Place/Alpha.swift")?.module == "Placed")
    }

    /// Build manifests never enter the index: no row, no phantom module, no unclearable guessed-module banner.
    @Test
    func manifestsAreNeverIndexed() async throws {
        let root = try Self.makeToolFirstRepo()
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        #expect(try engine.store.fileRow(path: "Package.swift") == nil)
        #expect(try engine.store.counts().files == 1)
        #expect(try engine.store.moduleNames() == ["Linter"])
    }

    /// A manifest row left behind by an older binary leaves on the first query of the new one — the phantom module and its banner go with it.
    @Test
    func aManifestRowFromAnOlderBinaryLeavesOnUpgrade() async throws {
        let root = try Self.makeToolFirstRepo()
        let first = try SiftEngine(directory: root)
        _ = try await first.ensureFresh()

        let parsedManifest = try TestSources.parsed(Self.toolFirstManifest, path: "Package.swift")
        try first.store.replaceFiles([parsedManifest]) { _ in ("VendorTools", true) }
        try first.store.setMetaValue("v0:written-by-an-older-binary", forKey: "resolution_fingerprint")
        #expect(try first.store.fileRow(path: "Package.swift") != nil)

        let upgraded = try SiftEngine(directory: root)
        _ = try await upgraded.ensureFresh()

        #expect(try upgraded.store.fileRow(path: "Package.swift") == nil)
        #expect(try upgraded.store.moduleNames() == ["Linter"])
        #expect(try upgraded.store.filesWithGuessedModule().isEmpty)
    }

    /// `init` still counts manifests apart even though the index never stores them.
    @Test
    func initStillCountsManifestsItWillNeverIndex() throws {
        let root = try Self.makeToolFirstRepo()
        let engine = try SiftEngine(directory: root)

        let report = try engine.initializeConfig(write: false, force: false)

        #expect(report.contains("scanned 1 Swift source file(s) (+1 build manifest(s))"))
    }
}
