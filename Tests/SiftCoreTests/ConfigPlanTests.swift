//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `sift init`: what it reports, what it proposes, and the two ways it must never damage an existing config.
///
/// The finding it exists to surface is that an unmapped file still *answers* — it just answers about a module invented from a directory name. Nothing errors, so without this command the misconfiguration is invisible until someone notices a digest is about the wrong thing.
@Suite(.temporaryDirectories)
struct ConfigPlanTests {
    private static func plan(paths: [String], root: URL? = nil) throws -> ConfigPlan {
        let repoRoot = try root ?? TestSources.makeTempDirectory()
        return ConfigPlan.make(repoRoot: repoRoot, config: SiftConfig(), paths: paths)
    }

    /// A manifest is a build file that happens to be Swift; counting it as unmapped reports a problem with no fix and buries the real ones.
    @Test
    func buildManifestsAreNotTreatedAsUnmappedSource() throws {
        let plan = try Self.plan(paths: ["Package.swift", "Tools/Linter/Package.swift", "Legacy/Widgets/Widget.swift"])

        #expect(plan.unresolvedGroups.map(\.prefix) == ["Legacy/Widgets"])
    }

    /// Manifests must not count as covered source either: otherwise a repo whose manifest resolves nothing reads "modules resolved from build files: 0 covering 1 file(s)" — the one "covered" file being `Package.swift` itself.
    @Test
    func buildManifestsAreNotCountedAsCoveredSourceEither() throws {
        let plan = try Self.plan(paths: ["Package.swift", "Legacy/Widgets/Widget.swift"])

        #expect(plan.filesScanned == 1)
        #expect(plan.manifestsScanned == 1)
        #expect(plan.resolvedFileCount == 0)
    }

    /// A tool-first layout (`<Area>/<Tool>/Sources|Tests/…`) must propose its sources and its tests as two entries — merged at tool granularity, accepting the proposal makes `digest <Tool>` return test files.
    @Test
    func toolFirstFallbackProposalsSplitSourcesFromTests() throws {
        let plan = try Self.plan(paths: [
            "VendorTools/Linter/Sources/Linter/A.swift",
            "VendorTools/Linter/Sources/Linter/B.swift",
            "VendorTools/Linter/Tests/LinterTests/C.swift",
        ])

        #expect(plan.unresolvedGroups.map(\.prefix) == ["VendorTools/Linter/Sources", "VendorTools/Linter/Tests"])
        #expect(plan.unresolvedGroups.map(\.proposedModule) == ["Linter", "LinterTests"])
    }

    @Test
    func unresolvedGroupsAreProposedWithTheirLastComponentAsAStartingName() throws {
        let plan = try Self.plan(paths: ["Legacy/Widgets/Widget.swift", "Legacy/Widgets/Gadget.swift", "Legacy/Gears/Gear.swift"])

        #expect(plan.unresolvedGroups.count == 2)
        #expect(plan.unresolvedGroups.first?.prefix == "Legacy/Widgets")
        #expect(plan.unresolvedGroups.first?.fileCount == 2)
        #expect(plan.unresolvedGroups.first?.proposedModule == "Widgets")
    }

    /// A `roots` allowlist would silently drop a Swift file sitting at the repo root, so it must not be proposed when one exists.
    @Test
    func rootsAreNotProposedWhenASwiftFileSitsAtTheRepoRoot() throws {
        let root = try TestSources.makeTempDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Docs"), withIntermediateDirectories: true)

        let withLooseFile = try Self.plan(paths: ["main.swift", "Sources/App/A.swift"], root: root)
        let withoutLooseFile = try Self.plan(paths: ["Sources/App/A.swift"], root: root)

        #expect(withLooseFile.skippableDirectories.isEmpty)
        #expect(withoutLooseFile.skippableDirectories == ["Docs"])
    }

    /// A real SwiftPM layout should need no `moduleMap` at all — the whole point of reading manifests.
    @Test
    func aSwiftPMLayoutResolvesWithoutAnyProposedMapping() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("struct Alpha {}", to: "Sources/Lib/Alpha.swift", in: root)

        let plan = ConfigPlan.make(repoRoot: root, config: SiftConfig(), paths: ["Package.swift", "Sources/Lib/Alpha.swift"])

        #expect(plan.unresolvedGroups.isEmpty)
        #expect(plan.resolvedModules["Lib"] == 1)
    }

    /// The shape end to end: a manifest below the repo root, every target on an explicit tool-first `path:` — misread, this yields "0 modules, N unresolved" with moduleMap proposals for a layout the manifest already declares completely.
    @Test
    func explicitPathTargetsBelowTheRepoRootNeedNoProposals() throws {
        let root = try TestSources.makeTempDirectory()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "VendorTools",
                targets: [
                    .executableTarget(name: "Linter", path: "Linter/Sources/Linter"),
                    .testTarget(name: "LinterTests", path: "Linter/Tests/LinterTests"),
                ]
            )
            """,
            to: "VendorTools/Package.swift",
            in: root
        )
        try TestSources.write("struct A {}", to: "VendorTools/Linter/Sources/Linter/A.swift", in: root)
        try TestSources.write("struct B {}", to: "VendorTools/Linter/Tests/LinterTests/B.swift", in: root)

        let plan = ConfigPlan.make(repoRoot: root, config: SiftConfig(), paths: [
            "VendorTools/Package.swift",
            "VendorTools/Linter/Sources/Linter/A.swift",
            "VendorTools/Linter/Tests/LinterTests/B.swift",
        ])

        #expect(plan.unresolvedGroups.isEmpty)
        #expect(plan.unmappedManifests.isEmpty)
        #expect(plan.resolvedModules == ["Linter": 1, "LinterTests": 1])
        #expect(plan.filesScanned == 2)
        #expect(plan.manifestsScanned == 1)
    }

    // MARK: Never damage what is already there

    /// `.sift.json` is hand-maintained — a module name this tool could only guess at is a human's answer — so a merge that overwrote one would destroy work the tool asked the user to invest.
    @Test
    func mergingKeepsExistingValuesAndCuration() throws {
        var existing = SiftConfig()
        existing.exclude = ["Generated/"]
        existing.indexStorePath = "elsewhere/index"
        existing.moduleMap = ["Legacy/Widgets": "TheRealName"]
        let plan = try Self.plan(paths: ["Legacy/Widgets/Widget.swift", "Legacy/Gears/Gear.swift"])

        let merged = plan.merged(onto: existing)

        #expect(merged.exclude == ["Generated/"])
        #expect(merged.indexStorePath == "elsewhere/index")
        #expect(merged.moduleMap["Legacy/Widgets"] == "TheRealName")
        #expect(merged.moduleMap["Legacy/Gears"] == "Gears")
    }

    /// `roots` is only worth writing when it actually excludes something, and then it must exclude exactly the directories with no Swift in them.
    @Test
    func rootsAreMergedOnlyWhenTheyExcludeSomething() throws {
        let root = try TestSources.makeTempDirectory()
        for name in ["Sources", "Docs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let plan = ConfigPlan.make(repoRoot: root, config: SiftConfig(), paths: ["Sources/App/A.swift"])

        let merged = plan.merged(onto: SiftConfig())

        #expect(merged.roots == ["Sources"])
    }

    /// The raw round-trip is what protects keys this binary's `SiftConfig` does not model — an older build must not delete a newer field by writing back what it understood, and a newer build must not delete a retired one.
    ///
    /// `exemplars` is exactly that: the key of a tool this binary no longer has, still committed in repositories it edits.
    @Test
    func writingPreservesKeysTheConfigTypeDoesNotModel() throws {
        let root = try TestSources.makeTempDirectory()
        try Data(#"{"exemplars":{"store":"X"},"futureField":{"kept":true}}"#.utf8)
            .write(to: ConfigFile.url(repoRoot: root))

        var json = ConfigFile.rawJSON(repoRoot: root)
        json["roots"] = ["Sources"]
        try ConfigFile.write(json, repoRoot: root)
        let reread = ConfigFile.rawJSON(repoRoot: root)

        #expect((reread["futureField"] as? [String: Any])?["kept"] as? Bool == true)
        #expect((reread["exemplars"] as? [String: String]) == ["store": "X"])
        #expect((reread["roots"] as? [String]) == ["Sources"])
    }

    /// The reader's half of the same promise, and the one a retired key actually depends on.
    ///
    /// ``SiftConfig/load(repoRoot:)`` treats a malformed config as an error rather than a default, so if a retired key decoded as a failure every query in a repository with a committed `exemplars` map would stop opening the engine — and the module map and excludes beside it would go down with a key nothing reads any more. Extra keys are ignored by construction (`decodeIfPresent`, per modelled key), which is a property worth a test rather than an inference from how `JSONDecoder` happens to behave.
    @Test
    func aRetiredKeyIsIgnoredRatherThanRejected() throws {
        let root = try TestSources.makeTempDirectory()
        let committed = #"""
        {"roots":["app"],"exclude":["Generated/"],"moduleMap":{"Legacy/Widgets":"Widgets"},
         "exemplars":{"store":"Catalogue.save"},"futureField":{"kept":true}}
        """#
        try Data(committed.utf8).write(to: ConfigFile.url(repoRoot: root))

        let loaded = try SiftConfig.load(repoRoot: root)

        #expect(loaded.roots == ["app"])
        #expect(loaded.exclude == ["Generated/"])
        #expect(loaded.moduleMap["Legacy/Widgets"] == "Widgets")
    }

    @Test
    func writeRefusesAnExistingConfigWithoutForce() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}", to: "Legacy/Widgets/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try Data(#"{"exemplars":{"store":"Alpha"}}"#.utf8).write(to: ConfigFile.url(repoRoot: root))
        let engine = try SiftEngine(directory: root)

        let refused = try engine.initializeConfig(write: true, force: false)

        #expect(refused.contains("already exists — pass --force"))
        #expect(!refused.contains("wrote .sift.json"))
        #expect(ConfigFile.rawJSON(repoRoot: root)["roots"] == nil)
    }

    @Test
    func forceMergesAndTheConfigTakesEffect() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}", to: "Legacy/Widgets/Alpha.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let wrote = try engine.initializeConfig(write: true, force: true)
        let reloaded = try SiftConfig.load(repoRoot: root)

        #expect(wrote.contains("wrote .sift.json"))
        #expect(reloaded.moduleMap["Legacy/Widgets"] == "Widgets")
    }
}
