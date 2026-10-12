//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `sift status`'s own "index store: none found" line, pinned to the same real build commands as `where`'s no-store note — a reader who follows either one has to actually end up with a store.
@Suite(.temporaryDirectories)
struct StatusNoStoreRemedyTests {
    @Test
    func statusNamesTheRealBuildCommandsRatherThanBuildTheProject() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Sources/Lib/Helper.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)

        #expect(status.contains("sift run -- swift build --build-tests for a SwiftPM package at the root"))
        #expect(status.contains("sift run -- xcodebuild -scheme <Scheme> build"))
        #expect(status.contains("indexStorePath set in .sift.json"))
        #expect(!status.contains("build the project to enable callers/overrides"))
        // An iOS project targets a generic device with no destination, which fails to sign; the note
        // names the destination that actually builds, narrowed to the host architecture so the simulator
        // SDK's second slice is never built for nothing.
        #if arch(x86_64)
        let hostArchitecture = "x86_64"
        #else
        let hostArchitecture = "arm64"
        #endif
        #expect(status.contains("-destination 'generic/platform=iOS Simulator' ARCHS=\(hostArchitecture)"))
        // The key names where to point, not just its own name — a build root is not a store.
        #expect(status.contains("pointing at the store directory itself"))
        // A SwiftPM build of a nested package is searched, so it is named among the places and needs no key.
        #expect(status.contains("the .build of each package nested below it (a directory holding a Package.swift)"))
        #expect(!status.contains("a SwiftPM build of a package nested below the repo root"))
        #expect(!status.contains("such as .build/debug/index/store"))
        // A custom -derivedDataPath gets its own store-location example, symmetrical with the SwiftPM one.
        #expect(status.contains("<path>/Index.noindex/DataStore for a custom -derivedDataPath"))
    }

    /// An `indexStorePath` that was read and rejected is named, on `status` and in `where`'s note alike — never the bare advice to set the key the reader already set.
    @Test
    func aRejectedIndexStorePathIsNamedWhereItWouldHaveActed() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Pkg/Sources/Lib/Helper.swift", in: root)
        try TestSources.write(#"{"indexStorePath": ".build/debug/index/store"}"#, to: ".sift.json", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)
        let answer = try await engine.lookup(symbol: "helper()", freshness: freshness)
        let rejection = "indexStorePath '.build/debug/index/store' in .sift.json is not an index store (no v<N>/units under it)"

        #expect(status.contains("index store: none found — \(rejection); build one:"), "\(status)")
        #expect(answer.contains("how to build one: sift help answers, section (index store); passed over: \(rejection)"), "\(answer)")
    }

    /// Where another probe found a store, the rejected setting is still named beside it: the store in use is not the one the key asked for.
    @Test
    func aRejectedIndexStorePathIsNamedBesideTheStoreFoundInstead() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func helper() {}", to: "Sources/Lib/Helper.swift", in: root)
        try TestSources.write(#"{"indexStorePath": "Pkg/.build"}"#, to: ".sift.json", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/index/store/v5/units"), withIntermediateDirectories: true)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let status = try engine.statusText(freshness: freshness)
        let line = status.split(separator: "\n").first { $0.hasPrefix("index store:") }.map(String.init) ?? ""

        #expect(line.hasSuffix("; passed over: indexStorePath 'Pkg/.build' in .sift.json is not an index store (no v<N>/units under it)"), "\(status)")
        #expect(line.contains(".build/index/store"), "\(status)")
    }
}
